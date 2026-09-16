import Darwin
import Foundation

func validateFileMetadata(_ st: stat, label: String, privateMaterial: Bool, effectiveUID: uid_t = geteuid()) throws {
    guard st.st_mode & S_IFMT == S_IFREG else {
        throw AgentError.invalidPayload("\(label) is not a regular file")
    }
    guard st.st_uid == effectiveUID || st.st_uid == 0 else {
        throw AgentError.invalidPayload("\(label) must be owned by the effective user or root")
    }
    let forbidden: mode_t = privateMaterial ? 0o077 : 0o022
    guard st.st_mode & forbidden == 0 else {
        throw AgentError.invalidPayload("\(label) has unsafe permissions: \(String(st.st_mode & 0o777, radix: 8))")
    }
}

func openSafeFile(path: String, label: String, privateMaterial: Bool) throws -> Int32 {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw AgentError.io("open \(label): \(String(cString: strerror(errno)))") }
    do {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AgentError.io("fstat \(label): \(String(cString: strerror(errno)))") }
        try validateFileMetadata(st, label: label, privateMaterial: privateMaterial)
        return fd
    } catch {
        close(fd)
        throw error
    }
}

func readSafeFile(path: String, label: String, privateMaterial: Bool) throws -> (Data, stat) {
    let fd = try openSafeFile(path: path, label: label, privateMaterial: privateMaterial)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var st = stat()
    guard fstat(fd, &st) == 0 else { throw AgentError.io("fstat \(label): \(String(cString: strerror(errno)))") }
    return (try handle.readToEnd() ?? Data(), st)
}

func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw AgentError.io("write: \(String(cString: strerror(errno)))") }
            offset += result
        }
    }
}

func replaceConfigFile(path: String, data: Data, privateMaterial: Bool) throws {
    let url = URL(fileURLWithPath: path)
    let parent = open(url.deletingLastPathComponent().resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw AgentError.io("open config directory: \(String(cString: strerror(errno)))") }
    defer { close(parent) }
    var directory = stat()
    guard fstat(parent, &directory) == 0,
          directory.st_uid == geteuid() || directory.st_uid == 0,
          directory.st_mode & 0o022 == 0 else {
        throw AgentError.io("config directory must be owned by the effective user or root and not group/world writable")
    }
    let name = url.lastPathComponent
    let original = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard original >= 0 else { throw AgentError.io("open config: \(String(cString: strerror(errno)))") }
    defer { close(original) }
    var metadata = stat()
    guard fstat(original, &metadata) == 0 else { throw AgentError.io("stat config: \(String(cString: strerror(errno)))") }
    try validateFileMetadata(metadata, label: "agent config", privateMaterial: false)
    let replacement = ".\(name).replacement.\(UUID().uuidString)"
    let fd = openat(parent, replacement, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw AgentError.io("create config replacement: \(String(cString: strerror(errno)))") }
    var isOpen = true
    defer {
        if isOpen { close(fd) }
        unlinkat(parent, replacement, 0)
    }
    try writeAll(data, fd: fd)
    let mode = metadata.st_mode & (privateMaterial ? 0o600 : 0o777)
    guard fchown(fd, metadata.st_uid, metadata.st_gid) == 0,
          fchmod(fd, mode) == 0,
          fsync(fd) == 0 else {
        throw AgentError.io("secure config replacement: \(String(cString: strerror(errno)))")
    }
    isOpen = false
    guard close(fd) == 0 else { throw AgentError.io("close config replacement: \(String(cString: strerror(errno)))") }
    var current = stat()
    guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, sameFile(metadata, current) else {
        throw AgentError.io("config changed during replacement")
    }
    guard renameat(parent, replacement, parent, name) == 0 else {
        throw AgentError.io("replace config: \(String(cString: strerror(errno)))")
    }
    guard fsync(parent) == 0 else { throw AgentError.io("sync config directory: \(String(cString: strerror(errno)))") }
}
