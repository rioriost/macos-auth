import Darwin
import Foundation

struct AgentClock {
    var wallTimeMs: () -> UInt64 = unixTimeMs
    var uptimeNs: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
}

struct Deadline {
    let uptimeNs: UInt64
    let clock: AgentClock

    init(milliseconds: UInt64, clock: AgentClock = AgentClock()) {
        self.clock = clock
        let (duration, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let (end, endOverflow) = clock.uptimeNs().addingReportingOverflow(duration)
        uptimeNs = overflow || endOverflow ? UInt64.max : end
    }

    private init(uptimeNs: UInt64, clock: AgentClock) {
        self.uptimeNs = uptimeNs
        self.clock = clock
    }

    func capped(milliseconds: UInt64) -> Deadline {
        Deadline(uptimeNs: min(uptimeNs, Deadline(milliseconds: milliseconds, clock: clock).uptimeNs), clock: clock)
    }

    var remainingMilliseconds: Int32 {
        let now = clock.uptimeNs()
        guard now < uptimeNs else { return 0 }
        return Int32(min(UInt64(Int32.max), (uptimeNs - now - 1) / 1_000_000 + 1))
    }

    func check() throws {
        guard remainingMilliseconds > 0 else { throw AgentError.timeout }
    }
}

func configureConnectedSocket(_ fd: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
          fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
          fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
        throw AgentError.socket(String(cString: strerror(errno)))
    }
}

private func waitForSocket(_ fd: Int32, events: Int16, deadline: Deadline) throws {
    while true {
        try deadline.check()
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, deadline.remainingMilliseconds)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw AgentError.io(String(cString: strerror(errno))) }
        guard result > 0 else { throw AgentError.timeout }
        try deadline.check()
        if descriptor.revents & Int16(POLLNVAL) != 0 {
            throw AgentError.io("socket closed")
        }
        return
    }
}

func readJSONFrame<T: Decodable>(from handle: FileHandle, deadline: Deadline) throws -> T {
    let lengthData = try readExactly(4, from: handle, deadline: deadline)
    let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= maxFrameLength else {
        throw AgentError.io("frame too large: \(length)")
    }
    let bodyData = try readExactly(Int(length), from: handle, deadline: deadline)
    return try JSONDecoder().decode(T.self, from: bodyData)
}

func writeJSONFrame<T: Encodable>(_ value: T, to handle: FileHandle, deadline: Deadline) throws {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maxFrameLength else {
        throw AgentError.io("frame too large: \(body.count)")
    }
    var length = UInt32(body.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(body)
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            try waitForSocket(handle.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
            let result = send(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, MSG_DONTWAIT)
            if result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard result > 0 else { throw AgentError.io("write: \(String(cString: strerror(errno)))") }
            offset += result
        }
    }
}

func readExactly(_ count: Int, from handle: FileHandle, deadline: Deadline) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < count {
            try waitForSocket(handle.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            let result = recv(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
            if result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard result > 0 else {
                throw AgentError.io(result == 0 ? "unexpected EOF" : "read: \(String(cString: strerror(errno)))")
            }
            offset += result
        }
    }
    return data
}

final class RequestLifetime {
    let deadline: Deadline
    private let expiresAtMs: UInt64
    private let fd: Int32
    private let lock = NSLock()
    private var cancelled = false

    init(fd: Int32, expiresAtMs: UInt64, connectionDeadline: Deadline) {
        self.fd = fd
        self.expiresAtMs = expiresAtMs
        let now = connectionDeadline.clock.wallTimeMs()
        deadline = connectionDeadline.capped(milliseconds: expiresAtMs > now ? expiresAtMs - now : 0)
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw AgentError.io("request cancelled") }
        do {
            try deadline.check()
            guard deadline.clock.wallTimeMs() < expiresAtMs else { throw AgentError.timeout }
            var byte: UInt8 = 0
            let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            // One frame per connection: EOF or unsolicited trailing bytes end the request.
            guard result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) else {
                throw AgentError.io("peer disconnected or sent trailing data")
            }
        } catch {
            cancelled = true
            throw error
        }
    }

    var isActive: Bool { (try? check()) != nil }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class ConnectionPool {
    private let slots: DispatchSemaphore
    private let workers = DispatchQueue(label: "macos-auth.connections", attributes: .concurrent)

    init(limit: Int = 8) { slots = DispatchSemaphore(value: limit) }

    @discardableResult
    func submit(_ work: @escaping () -> Void) -> Bool {
        guard slots.wait(timeout: .now()) == .success else { return false }
        workers.async {
            defer { self.slots.signal() }
            work()
        }
        return true
    }
}

func runSocketServer(
    listener: UnixSocketListener,
    once: Bool,
    handler: @escaping (FileHandle, Deadline) throws -> Void
) throws {
    let pool = ConnectionPool()
    let completion = LockedResult<Result<Void, Error>>()
    DispatchQueue.global().async {
        do {
            repeat {
                let handle = try listener.acceptFileHandle()
                let deadline = Deadline(milliseconds: 15_000)
                let admitted = pool.submit {
                    defer { try? handle.close() }
                    do { try handler(handle, deadline) }
                    catch { fputs("macos-auth-agent request failed: \(error)\n", stderr) }
                    if once { completion.complete(.success(())) }
                }
                if !admitted { try? handle.close() }
            } while !once
        } catch {
            completion.complete(.failure(error))
        }
    }
    // AppKit and LocalAuthentication initiation stay on the main thread.
    while completion.value == nil {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    try completion.value!.get()
}

final class UnixSocketListener {
    private static let bindLock = NSLock()
    private var fd: Int32 = -1
    private let path: String
    private var identity: stat?

    init(path: String) throws {
        guard !path.utf8.contains(0) else { throw AgentError.socket("invalid socket path") }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent).path
        self.path = path
        var addr = try Self.address(path: path)
        var directory = stat()
        guard lstat(parent, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid() || directory.st_uid == 0,
              directory.st_mode & 0o022 == 0 || (directory.st_uid == 0 && directory.st_mode & S_ISVTX != 0) else {
            throw AgentError.socket("socket parent must be a trusted directory")
        }
        try Self.removeStaleSocket(path: path, address: &addr)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.socket(String(cString: strerror(errno))) }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw AgentError.socket(String(cString: strerror(errno)))
            }
            Self.bindLock.lock()
            let previousMask = umask(0o077)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let bindError = errno
            umask(previousMask)
            Self.bindLock.unlock()
            guard result == 0 else { throw AgentError.socket(String(cString: strerror(bindError))) }
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == geteuid() else {
                throw AgentError.socket("cannot identify bound socket")
            }
            identity = st
            guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
                throw AgentError.socket(String(cString: strerror(errno)))
            }
        } catch {
            closeAndUnlink()
            throw error
        }
    }

    static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AgentError.socket("invalid or overlong socket path")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        return address
    }

    private static func removeStaleSocket(path: String, address: inout sockaddr_un) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw AgentError.socket(String(cString: strerror(errno)))
        }
        guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == geteuid() else {
            throw AgentError.socket("refusing to replace non-socket or foreign socket \(path)")
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw AgentError.socket(String(cString: strerror(errno))) }
        defer { Darwin.close(probe) }
        try configureConnectedSocket(probe)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result < 0, errno == ECONNREFUSED else {
            throw AgentError.socket("socket already active or cannot safely establish staleness: \(path)")
        }
        var current = stat()
        guard lstat(path, &current) == 0, sameFile(st, current), unlink(path) == 0 else {
            throw AgentError.socket("socket changed while checking staleness")
        }
    }

    func acceptFileHandle() throws -> FileHandle {
        var client: Int32
        repeat { client = accept(fd, nil, nil) } while client < 0 && errno == EINTR
        guard client >= 0 else { throw AgentError.socket(String(cString: strerror(errno))) }
        do { try configureConnectedSocket(client) }
        catch { Darwin.close(client); throw error }
        return FileHandle(fileDescriptor: client, closeOnDealloc: true)
    }

    func closeAndUnlink() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        if let identity {
            var current = stat()
            if lstat(path, &current) == 0 && sameFile(identity, current) { unlink(path) }
            self.identity = nil
        }
    }

    deinit { closeAndUnlink() }
}

func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
}
