use std::ffi::{CStr, CString, OsStr};
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
use std::path::{Component, Path};

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

fn name(value: &OsStr) -> io::Result<CString> {
    CString::new(value.as_bytes()).map_err(|_| invalid("path contains NUL"))
}

fn validate(file: &File, root_owned: bool, directory: bool, private: bool) -> io::Result<()> {
    let metadata = file.metadata()?;
    if directory != metadata.is_dir() || (!directory && !metadata.is_file()) {
        return Err(invalid("trusted path has incorrect file type"));
    }
    let owner = metadata.uid();
    if root_owned && owner != 0 {
        return Err(invalid(
            "trusted path has an untrusted owner (root required in production)",
        ));
    }
    let forbidden = if private { 0o077 } else { 0o022 };
    if metadata.mode() & forbidden != 0 {
        return Err(invalid(if private {
            "trusted path must not grant group/world permissions"
        } else {
            "trusted path must not be group/world writable"
        }));
    }
    Ok(())
}

pub fn open(path: &Path, root_owned: bool, directory: bool, private: bool) -> io::Result<File> {
    if root_owned && !path.is_absolute() {
        return Err(invalid("production trusted paths must be absolute"));
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut components = Vec::new();
    for component in absolute.components() {
        match component {
            Component::RootDir | Component::CurDir => {}
            Component::Normal(component) => components.push(name(component)?),
            _ => return Err(invalid("trusted path must not contain parent components")),
        }
    }
    let mut file = File::open("/")?;
    validate(&file, root_owned, true, false)?;
    for (index, component) in components.iter().enumerate() {
        let last = index + 1 == components.len();
        let is_directory = !last || directory;
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if is_directory { libc::O_DIRECTORY } else { 0 };
        let fd = unsafe { libc::openat(file.as_raw_fd(), component.as_ptr(), flags) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        file = unsafe { File::from_raw_fd(fd) };
        validate(&file, root_owned, is_directory, last && private)?;
    }
    validate(&file, root_owned, directory, private)?;
    Ok(file)
}

pub fn create_marker(directory: &File, marker: &str) -> io::Result<File> {
    let marker = name(OsStr::new(marker))?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            marker.as_ptr(),
            libc::O_WRONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_CREAT | libc::O_EXCL,
            0o600,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub fn cleanup_markers(directory: &File, now: u64) -> io::Result<()> {
    // fdopendir owns the duplicate; all entry access remains relative to the
    // validated directory even if its pathname is renamed concurrently.
    let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let dir = unsafe { libc::fdopendir(fd) };
    if dir.is_null() {
        unsafe { libc::close(fd) };
        return Err(io::Error::last_os_error());
    }
    loop {
        let entry = unsafe { libc::readdir(dir) };
        if entry.is_null() {
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes().len() != 64 || !name.to_bytes().iter().all(u8::is_ascii_hexdigit) {
            continue;
        }
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            continue;
        }
        let file = unsafe { File::from_raw_fd(fd) };
        if !file.metadata().is_ok_and(|metadata| metadata.is_file()) {
            continue;
        }
        use std::io::Read;
        let mut contents = String::new();
        if file.take(128).read_to_string(&mut contents).is_ok()
            && super::parse_expires_at_ms(&contents).is_some_and(|expiry| expiry < now)
        {
            unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) };
        }
    }
    unsafe { libc::closedir(dir) };
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::PathBuf;

    fn directory(label: &str) -> PathBuf {
        let path = PathBuf::from(format!(".trust-{label}-{}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[test]
    fn production_owner_check_applies_to_files_and_directories() {
        let dir = directory("owner");
        let path = dir.join("key");
        std::fs::write(&path, "original").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let file = File::open(&path).unwrap();
        let directory = File::open(&dir).unwrap();
        if unsafe { libc::geteuid() } != 0 {
            assert!(validate(&file, true, false, true).is_err());
            assert!(validate(&file, true, false, false).is_err());
            assert!(validate(&directory, true, true, true).is_err());
            assert!(validate(&directory, true, true, false).is_err());
        }
        assert!(open(Path::new("/usr/bin/true"), true, false, false).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn trusted_read_keeps_validated_inode_after_path_replacement() {
        let dir = directory("read");
        let path = dir.join("key");
        std::fs::write(&path, "original").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut file = open(&path, false, false, true).unwrap();
        std::fs::rename(&path, dir.join("old")).unwrap();
        std::fs::write(&path, "replacement").unwrap();
        let mut contents = String::new();
        file.read_to_string(&mut contents).unwrap();
        assert_eq!(contents, "original");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn replay_operations_stay_on_validated_directory_and_ignore_symlinks() {
        let dir = directory("replay");
        let cache_path = dir.join("cache");
        let moved_path = dir.join("moved");
        let untrusted_path = dir.join("replacement");
        std::fs::create_dir(&cache_path).unwrap();
        std::fs::set_permissions(&cache_path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let cache = open(&cache_path, false, true, true).unwrap();
        std::fs::rename(&cache_path, &moved_path).unwrap();
        std::fs::create_dir(&untrusted_path).unwrap();
        symlink("replacement", &cache_path).unwrap();
        let marker = "a".repeat(64);
        writeln!(create_marker(&cache, &marker).unwrap(), "expires_at_ms=1").unwrap();
        assert!(moved_path.join(&marker).is_file());
        assert!(!untrusted_path.join(&marker).exists());
        let link = "b".repeat(64);
        symlink(&marker, moved_path.join(&link)).unwrap();
        cleanup_markers(&cache, 2).unwrap();
        assert!(!moved_path.join(&marker).exists());
        assert!(std::fs::symlink_metadata(moved_path.join(&link))
            .unwrap()
            .is_symlink());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
