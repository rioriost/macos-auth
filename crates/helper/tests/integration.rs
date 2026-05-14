use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const HOST_PRIVATE: &str = "0707070707070707070707070707070707070707070707070707070707070707";
const HOST_PUBLIC: &str = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
const AGENT_PRIVATE: &str = "0909090909090909090909090909090909090909090909090909090909090909";
const AGENT_PUBLIC: &str = "fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618";

#[test]
fn request_to_fake_agent_exits_success_when_approved() {
    let helper = env!("CARGO_BIN_EXE_macos-auth-helper");
    let socket = unique_socket_path("approved");
    let socket_string = socket.to_string_lossy().to_string();
    let _ = fs::remove_file(&socket);

    let mut fake_agent = Command::new(helper)
        .args([
            "fake-agent",
            "--socket",
            &socket_string,
            "--host-pubkey-hex",
            HOST_PUBLIC,
            "--agent-key-hex",
            AGENT_PRIVATE,
            "--once",
        ])
        .spawn()
        .expect("spawn fake agent");

    wait_for_socket(&socket);

    let request_status = Command::new(helper)
        .args([
            "request",
            "--socket",
            &socket_string,
            "--key-hex",
            HOST_PRIVATE,
            "--agent-pubkey-hex",
            AGENT_PUBLIC,
            "--host-id",
            "host-abc",
            "--hostname",
            "linux.example.com",
            "--user",
            "alice",
            "--ruser",
            "alice",
            "--tty",
            "pts/3",
        ])
        .status()
        .expect("run request");

    assert_eq!(request_status.code(), Some(0));

    let fake_status = fake_agent.wait().expect("wait fake agent");
    assert!(fake_status.success());
    let _ = fs::remove_file(socket);
}

#[test]
fn request_to_fake_agent_accepts_key_files() {
    let helper = env!("CARGO_BIN_EXE_macos-auth-helper");
    let socket = unique_socket_path("files");
    let socket_string = socket.to_string_lossy().to_string();
    let host_key_file = unique_file_path("host-key");
    let agent_key_file = unique_file_path("agent-key");
    let host_pubkey_file = unique_file_path("host-pub");
    let agent_pubkey_file = unique_file_path("agent-pub");
    let _ = fs::remove_file(&socket);

    write_file_with_mode(
        &host_key_file,
        &format!("private_key_hex={HOST_PRIVATE}\n"),
        0o600,
    );
    write_file_with_mode(
        &agent_key_file,
        &format!("private_key_hex={AGENT_PRIVATE}\n"),
        0o600,
    );
    write_file_with_mode(
        &host_pubkey_file,
        &format!("public_key_hex={HOST_PUBLIC}\n"),
        0o644,
    );
    write_file_with_mode(
        &agent_pubkey_file,
        &format!("public_key_hex={AGENT_PUBLIC}\n"),
        0o644,
    );

    let mut fake_agent = Command::new(helper)
        .args([
            "fake-agent",
            "--socket",
            &socket_string,
            "--host-pubkey-file",
            &host_pubkey_file.to_string_lossy(),
            "--agent-key-file",
            &agent_key_file.to_string_lossy(),
            "--once",
        ])
        .spawn()
        .expect("spawn fake agent");

    wait_for_socket(&socket);

    let request_status = Command::new(helper)
        .args([
            "request",
            "--socket",
            &socket_string,
            "--key-file",
            &host_key_file.to_string_lossy(),
            "--agent-pubkey-file",
            &agent_pubkey_file.to_string_lossy(),
            "--host-id",
            "host-abc",
            "--hostname",
            "linux.example.com",
            "--user",
            "alice",
        ])
        .status()
        .expect("run request");

    assert_eq!(request_status.code(), Some(0));
    let fake_status = fake_agent.wait().expect("wait fake agent");
    assert!(fake_status.success());

    for path in [
        socket,
        host_key_file,
        agent_key_file,
        host_pubkey_file,
        agent_pubkey_file,
    ] {
        let _ = fs::remove_file(path);
    }
}

#[test]
fn request_uses_config_file_defaults() {
    let helper = env!("CARGO_BIN_EXE_macos-auth-helper");
    let socket = unique_socket_path("config");
    let socket_string = socket.to_string_lossy().to_string();
    let host_key_file = unique_file_path("cfg-host-key");
    let agent_key_file = unique_file_path("cfg-agent-key");
    let host_pubkey_file = unique_file_path("cfg-host-pub");
    let agent_pubkey_file = unique_file_path("cfg-agent-pub");
    let config_file = unique_file_path("config");

    write_file_with_mode(
        &host_key_file,
        &format!("private_key_hex={HOST_PRIVATE}\n"),
        0o600,
    );
    write_file_with_mode(
        &agent_key_file,
        &format!("private_key_hex={AGENT_PRIVATE}\n"),
        0o600,
    );
    write_file_with_mode(
        &host_pubkey_file,
        &format!("public_key_hex={HOST_PUBLIC}\n"),
        0o644,
    );
    write_file_with_mode(
        &agent_pubkey_file,
        &format!("public_key_hex={AGENT_PUBLIC}\n"),
        0o644,
    );
    write_file_with_mode(
        &config_file,
        &format!(
            "socket_path = {:?}\nhost_key_file = {:?}\nagent_pubkey_file = {:?}\nhost_id = \"host-abc\"\nhostname = \"linux.example.com\"\nservice = \"sudo\"\n",
            socket_string,
            host_key_file.to_string_lossy().to_string(),
            agent_pubkey_file.to_string_lossy().to_string()
        ),
        0o644,
    );

    let mut fake_agent = Command::new(helper)
        .args([
            "fake-agent",
            "--socket",
            &socket_string,
            "--host-pubkey-file",
            &host_pubkey_file.to_string_lossy(),
            "--agent-key-file",
            &agent_key_file.to_string_lossy(),
            "--once",
        ])
        .spawn()
        .expect("spawn fake agent");

    wait_for_socket(&socket);

    let request_status = Command::new(helper)
        .args([
            "request",
            "--config",
            &config_file.to_string_lossy(),
            "--user",
            "alice",
        ])
        .status()
        .expect("run request");

    assert_eq!(request_status.code(), Some(0));
    let fake_status = fake_agent.wait().expect("wait fake agent");
    assert!(fake_status.success());

    for path in [
        socket,
        host_key_file,
        agent_key_file,
        host_pubkey_file,
        agent_pubkey_file,
        config_file,
    ] {
        let _ = fs::remove_file(path);
    }
}

#[test]
fn request_exits_unsafe_config_for_permissive_private_key_file() {
    let helper = env!("CARGO_BIN_EXE_macos-auth-helper");
    let socket = unique_socket_path("unsafe");
    let socket_string = socket.to_string_lossy().to_string();
    let host_key_file = unique_file_path("unsafe-host-key");
    write_file_with_mode(
        &host_key_file,
        &format!("private_key_hex={HOST_PRIVATE}\n"),
        0o644,
    );

    let status = Command::new(helper)
        .args([
            "request",
            "--socket",
            &socket_string,
            "--key-file",
            &host_key_file.to_string_lossy(),
            "--agent-pubkey-hex",
            AGENT_PUBLIC,
            "--host-id",
            "host-abc",
            "--hostname",
            "linux.example.com",
            "--user",
            "alice",
        ])
        .status()
        .expect("run request");

    assert_eq!(status.code(), Some(31));
    let _ = fs::remove_file(host_key_file);
}

#[test]
fn request_exits_unavailable_when_socket_is_missing() {
    let helper = env!("CARGO_BIN_EXE_macos-auth-helper");
    let socket = unique_socket_path("missing");
    let socket_string = socket.to_string_lossy().to_string();
    let _ = fs::remove_file(&socket);

    let status = Command::new(helper)
        .args([
            "request",
            "--socket",
            &socket_string,
            "--key-hex",
            HOST_PRIVATE,
            "--agent-pubkey-hex",
            AGENT_PUBLIC,
            "--host-id",
            "host-abc",
            "--hostname",
            "linux.example.com",
            "--user",
            "alice",
        ])
        .status()
        .expect("run request");

    assert_eq!(status.code(), Some(10));
}

fn wait_for_socket(path: &std::path::Path) {
    for _ in 0..50 {
        if path.exists() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("socket did not appear: {}", path.display());
}

fn write_file_with_mode(path: &std::path::Path, contents: &str, mode: u32) {
    fs::write(path, contents).expect("write key file");
    let mut permissions = fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(mode);
    fs::set_permissions(path, permissions).expect("set permissions");
}

fn unique_file_path(label: &str) -> std::path::PathBuf {
    let now_micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_micros();
    std::path::PathBuf::from(format!(
        "/tmp/ma-{label}-{}-{now_micros}.txt",
        std::process::id()
    ))
}

fn unique_socket_path(label: &str) -> std::path::PathBuf {
    let now_micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_micros();
    std::path::PathBuf::from(format!(
        "/tmp/ma-{label}-{}-{now_micros}.sock",
        std::process::id()
    ))
}
