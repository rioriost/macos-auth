use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::{ffi::OsStrExt, net::UnixStream};
use std::path::Path;
use std::time::Instant;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("agent operation deadline exceeded")]
    Timeout,
    #[error("transport I/O: {0}")]
    Io(io::Error),
    #[error("invalid frame: {0}")]
    Json(#[from] serde_json::Error),
    #[error("frame too large: {0} bytes")]
    Oversized(usize),
}

impl From<io::Error> for TransportError {
    fn from(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => Self::Timeout,
            _ => Self::Io(error),
        }
    }
}

pub fn check_deadline(deadline: Instant) -> Result<(), TransportError> {
    if Instant::now() >= deadline {
        Err(TransportError::Timeout)
    } else {
        Ok(())
    }
}

fn wait(stream: &UnixStream, events: libc::c_short, deadline: Instant) -> io::Result<()> {
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or_else(|| io::Error::from(io::ErrorKind::TimedOut))?;
        let timeout = remaining
            .as_millis()
            .saturating_add(1)
            .min(i32::MAX as u128) as i32;
        let mut pollfd = libc::pollfd {
            fd: stream.as_raw_fd(),
            events,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut pollfd, 1, timeout) };
        if result > 0 {
            if pollfd.revents & libc::POLLNVAL != 0 {
                return Err(io::Error::from_raw_os_error(libc::EBADF));
            }
            return Ok(());
        }
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

pub struct DeadlineStream {
    stream: UnixStream,
    deadline: Instant,
}

impl DeadlineStream {
    pub fn connect(path: &Path, deadline: Instant) -> Result<Self, TransportError> {
        check_deadline(deadline)?;
        let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        address.sun_family = libc::AF_UNIX as libc::sa_family_t;
        let bytes = path.as_os_str().as_bytes();
        if bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid socket path").into());
        }
        for (destination, source) in address.sun_path.iter_mut().zip(bytes) {
            *destination = *source as libc::c_char;
        }
        let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let stream = unsafe { UnixStream::from_raw_fd(fd) };
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error().into());
        }
        stream.set_nonblocking(true)?;
        let address_len = std::mem::size_of_val(&address) as libc::socklen_t;
        loop {
            check_deadline(deadline)?;
            let result = unsafe {
                libc::connect(
                    fd,
                    &address as *const _ as *const libc::sockaddr,
                    address_len,
                )
            };
            if result == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EISCONN) => break,
                Some(libc::EINTR) => continue,
                Some(libc::EINPROGRESS) | Some(libc::EALREADY) => {
                    wait(&stream, libc::POLLOUT, deadline)?;
                    if let Some(error) = stream.take_error()? {
                        return Err(error.into());
                    }
                    break;
                }
                // Linux AF_UNIX reports EAGAIN when the listen backlog is full;
                // no connection is pending, so retry rather than treating POLLOUT as success.
                Some(libc::EAGAIN) => {
                    std::thread::sleep(
                        deadline
                            .saturating_duration_since(Instant::now())
                            .min(std::time::Duration::from_millis(1)),
                    );
                }
                _ => return Err(error.into()),
            }
        }
        check_deadline(deadline)?;
        Ok(Self { stream, deadline })
    }

    #[cfg(test)]
    pub fn from_stream(stream: UnixStream, deadline: Instant) -> Self {
        stream.set_nonblocking(true).unwrap();
        Self { stream, deadline }
    }

    fn transfer<T>(
        &mut self,
        events: libc::c_short,
        mut operation: impl FnMut(&mut UnixStream) -> io::Result<T>,
    ) -> io::Result<T> {
        loop {
            check_deadline(self.deadline).map_err(|_| io::Error::from(io::ErrorKind::TimedOut))?;
            match operation(&mut self.stream) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait(&self.stream, events, self.deadline)?;
                }
                result => return result,
            }
        }
    }
}

impl Read for DeadlineStream {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.transfer(libc::POLLIN, |stream| stream.read(bytes))
    }
}

impl Write for DeadlineStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.transfer(libc::POLLOUT, |stream| stream.write(bytes))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn blocked_write_obeys_deadline() {
        let (writer, _reader) = UnixStream::pair().unwrap();
        let start = Instant::now();
        let mut stream = DeadlineStream::from_stream(writer, start + Duration::from_millis(80));
        let error = stream.write_all(&vec![0; 8 * 1024 * 1024]).unwrap_err();
        assert!(matches!(
            TransportError::from(error),
            TransportError::Timeout
        ));
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn timeout_error_kinds_are_not_protocol_errors() {
        for kind in [io::ErrorKind::WouldBlock, io::ErrorKind::TimedOut] {
            assert!(matches!(
                TransportError::from(io::Error::from(kind)),
                TransportError::Timeout
            ));
        }

        assert!(matches!(
            TransportError::from(io::Error::from(io::ErrorKind::UnexpectedEof)),
            TransportError::Io(_)
        ));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn full_unix_listen_backlog_obeys_connect_deadline() {
        use std::os::unix::net::UnixListener;
        let path = std::env::current_dir()
            .unwrap()
            .join(format!(".backlog-{}", std::process::id()));
        let listener = UnixListener::bind(&path).unwrap();
        assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
        let start = Instant::now();
        let mut connections = Vec::new();
        loop {
            match DeadlineStream::connect(&path, Instant::now() + Duration::from_millis(60)) {
                Ok(connection) => {
                    connections.push(connection);
                    assert!(connections.len() < 10, "listen backlog did not fill");
                }
                Err(TransportError::Timeout) => break,
                Err(error) => panic!("{error}"),
            }
        }
        assert!(start.elapsed() < Duration::from_secs(2));
        std::fs::remove_file(path).unwrap();
    }
}
