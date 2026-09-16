use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use ed25519_dalek::SigningKey;
use macos_auth_protocol::{AuthMethod, AuthResponseBody, Decision, SignedAuthRequest};

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
    std::env::current_dir()
        .unwrap()
        .join(format!(".t-{label}-{}-{now_micros}", std::process::id()))
}

fn unique_socket_path(label: &str) -> std::path::PathBuf {
    let now_micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_micros();
    // AF_UNIX has a short pathname limit (104 bytes on macOS).
    std::env::current_dir().unwrap().join(format!(
        ".s-{}-{now_micros:x}-{:x}",
        std::process::id(),
        label.bytes().fold(0u32, |hash, byte| hash
            .wrapping_mul(31)
            .wrapping_add(byte as u32))
    ))
}

fn request_command(socket: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"));
    command
        .args([
            "request",
            "--key-hex",
            HOST_PRIVATE,
            "--agent-pubkey-hex",
            AGENT_PUBLIC,
            "--host-id",
            "test-host",
            "--hostname",
            "test.example",
            "--user",
            "alice",
        ])
        .arg("--socket")
        .arg(socket);
    command
}

fn read_request(stream: &mut UnixStream) -> SignedAuthRequest {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut length = [0; 4];
    stream.read_exact(&mut length).unwrap();
    let mut bytes = vec![0; u32::from_be_bytes(length) as usize];
    stream.read_exact(&mut bytes).unwrap();
    let request: SignedAuthRequest = serde_json::from_slice(&bytes).unwrap();
    request.verify(&hex::decode(HOST_PUBLIC).unwrap()).unwrap();
    request
}

fn send_bytes(stream: &mut UnixStream, bytes: &[u8]) {
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .unwrap();
    stream.write_all(bytes).unwrap();
}

fn with_agent(
    label: &str,
    timeout_ms: u64,
    serve: impl FnOnce(UnixStream) + Send + 'static,
) -> (i32, Duration) {
    let path = unique_socket_path(label);
    let listener = UnixListener::bind(&path).unwrap();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        serve(stream);
    });
    let start = Instant::now();
    let output = request_command(&path)
        .arg("--timeout-ms")
        .arg(timeout_ms.to_string())
        .output()
        .unwrap();
    let elapsed = start.elapsed();
    server.join().unwrap();
    fs::remove_file(path).unwrap();
    (output.status.code().unwrap(), elapsed)
}

#[test]
fn all_signed_decisions_map_to_documented_exit_codes() {
    for (decision, expected) in [
        (Decision::Approved, 0),
        (Decision::Denied, 20),
        (Decision::Unavailable, 10),
        (Decision::Cancelled, 11),
        (Decision::Failed, 12),
    ] {
        let (exit, _) = with_agent("decisions", 2000, move |mut stream| {
            let request = read_request(&mut stream);
            assert_eq!(
                request.body.expires_at_ms - request.body.created_at_ms,
                2000
            );
            let response = AuthResponseBody::for_request(
                &request.body,
                decision,
                AuthMethod::BiometricOrWatch,
                request.body.created_at_ms,
                request.body.expires_at_ms,
                "agent",
            )
            .unwrap()
            .sign(&SigningKey::from_bytes(&[9; 32]))
            .unwrap();
            send_bytes(&mut stream, &serde_json::to_vec(&response).unwrap());
        });
        assert_eq!(exit, expected, "{decision:?}");
    }
}

#[test]
fn invalid_signatures_are_hard_fail_for_every_decision() {
    for decision in [
        Decision::Approved,
        Decision::Denied,
        Decision::Unavailable,
        Decision::Cancelled,
        Decision::Failed,
    ] {
        let (exit, _) = with_agent("signature", 2000, move |mut stream| {
            let request = read_request(&mut stream);
            let response = AuthResponseBody::for_request(
                &request.body,
                decision,
                AuthMethod::None,
                request.body.created_at_ms,
                request.body.expires_at_ms,
                "agent",
            )
            .unwrap()
            .sign(&SigningKey::from_bytes(&[8; 32]))
            .unwrap();
            send_bytes(&mut stream, &serde_json::to_vec(&response).unwrap());
        });
        assert_eq!(exit, 30, "{decision:?}");
    }
}

#[test]
fn stalled_or_trickled_responses_use_one_absolute_deadline() {
    for trickle in [false, true] {
        let (exit, elapsed) = with_agent("timeout", 120, move |mut stream| {
            let request = read_request(&mut stream);
            assert_eq!(request.body.expires_at_ms - request.body.created_at_ms, 120);
            if !trickle {
                std::thread::sleep(Duration::from_millis(300));
                return;
            }
            // Every individual byte arrives well within a relative read timeout.
            for byte in [0, 0, 0, 30, b'{', b' ', b' ', b' ', b' '] {
                if stream.write_all(&[byte]).is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(45));
            }
        });
        assert_eq!(exit, 10);
        assert!(elapsed < Duration::from_millis(500), "{elapsed:?}");
    }
}

#[test]
fn truncated_invalid_and_oversized_frames_remain_protocol_failures() {
    let payloads = [
        vec![],
        vec![0, 0],
        vec![0, 0, 0, 10, b'{', b'}'],
        [4u32.to_be_bytes().as_slice(), b"nope"].concat(),
        [2u32.to_be_bytes().as_slice(), b"{}"].concat(),
        (1024u32 * 1024 + 1).to_be_bytes().to_vec(),
    ];
    for payload in payloads {
        let (exit, _) = with_agent("malformed", 2000, move |mut stream| {
            read_request(&mut stream);
            stream.write_all(&payload).unwrap();
        });
        assert_eq!(exit, 32);
    }
}

#[test]
fn signed_late_approval_cannot_extend_request_lifetime() {
    let (exit, elapsed) = with_agent("late", 80, |mut stream| {
        let request = read_request(&mut stream);
        let response = AuthResponseBody::for_request(
            &request.body,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            request.body.created_at_ms,
            request.body.expires_at_ms + 60_000,
            "agent",
        )
        .unwrap()
        .sign(&SigningKey::from_bytes(&[9; 32]))
        .unwrap();
        std::thread::sleep(Duration::from_millis(180));
        let bytes = serde_json::to_vec(&response).unwrap();
        let _ = stream.write_all(&(bytes.len() as u32).to_be_bytes());
        let _ = stream.write_all(&bytes);
    });
    assert_eq!(exit, 10);
    assert!(elapsed < Duration::from_millis(500));
}

#[test]
fn invalid_timeout_and_relative_socket_are_configuration_failures() {
    let path = unique_socket_path("invalid");
    for timeout in ["0", "18446744073709551615"] {
        let output = request_command(&path)
            .args(["--timeout-ms", timeout])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(31));
    }
    let output = request_command(Path::new("relative.sock"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(31));
}

#[test]
fn trust_rejects_symlink_files_ancestors_and_writable_ancestors() {
    let directory = unique_file_path("trust");
    fs::create_dir(&directory).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
    let key = directory.join("key");
    write_file_with_mode(&key, HOST_PRIVATE, 0o600);
    let link = directory.join("link");
    std::os::unix::fs::symlink(&key, &link).unwrap();
    let run = |path: &Path| {
        Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"))
            .args(["request", "--key-file"])
            .arg(path)
            .args([
                "--agent-pubkey-hex",
                AGENT_PUBLIC,
                "--socket",
                "/nonexistent",
                "--host-id",
                "host",
                "--hostname",
                "host",
                "--user",
                "alice",
            ])
            .output()
            .unwrap()
            .status
            .code()
    };
    assert_eq!(run(&key), Some(10));
    assert_eq!(run(&link), Some(31));
    let directory_link = unique_file_path("ancestor-link");
    std::os::unix::fs::symlink(&directory, &directory_link).unwrap();
    assert_eq!(run(&directory_link.join("key")), Some(31));
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(run(&key), Some(31));
    fs::remove_file(directory_link).unwrap();
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn production_rejects_development_owner_relative_paths_and_inline_keys() {
    let config = unique_file_path("production");
    write_file_with_mode(&config, "host_id = \"host\"\n", 0o644);
    let helper = env!("CARGO_BIN_EXE_macos-auth-helper");
    if unsafe { libc::geteuid() } != 0 {
        let output = Command::new(helper)
            .args([
                "request",
                "--require-root-owned",
                "--user",
                "alice",
                "--config",
            ])
            .arg(&config)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(31));
        assert!(String::from_utf8_lossy(&output.stderr).contains("owner"));
    }
    let output = request_command(Path::new("/nonexistent"))
        .arg("--require-root-owned")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(31));
    let output = Command::new(helper)
        .args([
            "request",
            "--require-root-owned",
            "--user",
            "alice",
            "--config",
            "relative.toml",
        ])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(31));
    fs::remove_file(config).unwrap();
}

#[test]
fn relocated_config_preserves_options_and_never_references_development_keys() {
    let source = unique_file_path("relocate");
    write_file_with_mode(
        &source,
        r#"
socket_path = "/development/agent.sock"
host_key_file = "/development/private.key"
agent_pubkey_file = "/development/agent.pub"
host_id = "host with \"quotes\""
hostname = "test.example"
service = "custom"
key_id = "custom-key"
timeout_ms = 1234
allowed_future_skew_ms = 5678
replay_cache_dir = "/development/replay"
[future_options]
value = "preserved"
"#,
        0o644,
    );
    let output = Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"))
        .args(["prepare-config", "--source"])
        .arg(&source)
        .args([
            "--socket",
            "/run/macos-auth/agent.sock",
            "--host-key-file",
            "/etc/macos-auth/host_ed25519.key",
            "--agent-pubkey-file",
            "/etc/macos-auth/agents.d/agent.pub",
            "--replay-cache-dir",
            "/var/lib/macos-auth/replay",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(!text.contains("/development/"));
    let config: toml::Value = toml::from_str(&text).unwrap();
    assert_eq!(config["host_id"].as_str(), Some("host with \"quotes\""));
    assert_eq!(config["timeout_ms"].as_integer(), Some(1234));
    assert_eq!(config["service"].as_str(), Some("custom"));
    assert_eq!(config["key_id"].as_str(), Some("custom-key"));
    assert_eq!(config["allowed_future_skew_ms"].as_integer(), Some(5678));
    assert_eq!(
        config["future_options"]["value"].as_str(),
        Some("preserved")
    );
    assert_eq!(
        config["host_key_file"].as_str(),
        Some("/etc/macos-auth/host_ed25519.key")
    );
    assert_eq!(
        config["agent_pubkey_file"].as_str(),
        Some("/etc/macos-auth/agents.d/agent.pub")
    );
    fs::remove_file(source).unwrap();
}

#[test]
fn development_setup_escapes_toml_and_uses_absolute_paths() {
    let output_dir = unique_file_path("setup");
    let public_key = unique_file_path("setup-agent");
    write_file_with_mode(&public_key, AGENT_PUBLIC, 0o644);
    let output = Command::new("../../scripts/linux-dev-setup.sh")
        .env_remove("USER")
        .args([
            "--host-id",
            "host\"quoted\\value",
            "--hostname",
            "test.example",
            "--agent-pubkey-file",
        ])
        .arg(&public_key)
        .arg("--out-dir")
        .arg(&output_dir)
        .arg("--helper-bin")
        .arg(env!("CARGO_BIN_EXE_macos-auth-helper"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let username = Command::new("id").arg("-un").output().unwrap();
    assert!(username.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains(&format!(
        "--user \"{}\"",
        String::from_utf8_lossy(&username.stdout).trim()
    )));
    let text = fs::read_to_string(output_dir.join("config.toml")).unwrap();
    let config: toml::Value = toml::from_str(&text).unwrap();
    assert_eq!(config["host_id"].as_str(), Some("host\"quoted\\value"));
    for field in ["socket_path", "host_key_file", "agent_pubkey_file"] {
        assert!(Path::new(config[field].as_str().unwrap()).is_absolute());
    }
    fs::remove_dir_all(output_dir).unwrap();
    fs::remove_file(public_key).unwrap();
}

#[test]
fn development_setup_surfaces_username_lookup_failure() {
    let directory = unique_file_path("username-failure");
    fs::create_dir(&directory).unwrap();
    write_file_with_mode(
        &directory.join("id"),
        "#!/bin/sh\necho 'username lookup failed' >&2\nexit 43\n",
        0o755,
    );
    let path = std::env::join_paths(
        std::iter::once(directory.clone())
            .chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
    )
    .unwrap();
    let output_dir = directory.join("output");
    let output = Command::new("../../scripts/linux-dev-setup.sh")
        .env_remove("USER")
        .env("PATH", path)
        .args([
            "--host-id",
            "host",
            "--hostname",
            "host.example",
            "--agent-pubkey-file",
            "unused.pub",
        ])
        .arg("--out-dir")
        .arg(&output_dir)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(43));
    assert!(String::from_utf8_lossy(&output.stderr).contains("username lookup failed"));
    assert!(!output_dir.exists());
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn config_key_path_validates_actual_required_fields() {
    let config = unique_file_path("bad-source");
    for contents in [
        "socket_path = \"relative.sock\"\nhost_id = \"host\"\nhostname = \"host\"",
        "host_id = \"host\"\nhostname = \"host\"",
        "socket_path = \"/agent.sock\"\nhost_id = 42",
        "socket_path = \"/agent.sock\"\ntimeout_ms = 0",
    ] {
        write_file_with_mode(&config, contents, 0o644);
        let output = Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"))
            .args(["config-key-path", "--config"])
            .arg(&config)
            .args(["--key", "host"])
            .output()
            .unwrap();
        assert!(!output.status.success());
    }
    fs::remove_file(config).unwrap();
}

#[test]
fn relocated_configuration_works_after_source_directory_is_removed() {
    let directory = unique_file_path("relocated-request");
    let source_dir = directory.join("source");
    let destination = directory.join("installed");
    fs::create_dir_all(&source_dir).unwrap();
    fs::create_dir_all(&destination).unwrap();
    let host = source_dir.join("custom-host.key");
    let agent = source_dir.join("custom-agent.pub");
    write_file_with_mode(&host, HOST_PRIVATE, 0o600);
    write_file_with_mode(&agent, AGENT_PUBLIC, 0o644);
    let socket = unique_socket_path("relocated");
    let listener = UnixListener::bind(&socket).unwrap();
    let source = source_dir.join("config.toml");
    write_file_with_mode(
        &source,
        &format!(
            "host_id = \"host\"\nhostname = \"host\"\nsocket_path = {:?}\nhost_key_file = {:?}\nagent_pubkey_file = {:?}\n",
            socket.to_str().unwrap(), host.to_str().unwrap(), agent.to_str().unwrap(),
        ),
        0o644,
    );
    for (key, expected) in [("host", &host), ("agent", &agent)] {
        let output = Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"))
            .args(["config-key-path", "--config"])
            .arg(&source)
            .args(["--key", key])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap().trim(),
            expected.to_str().unwrap()
        );
    }
    let output = Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"))
        .args(["prepare-config", "--source"])
        .arg(&source)
        .arg("--socket")
        .arg(&socket)
        .arg("--host-key-file")
        .arg(destination.join("host.key"))
        .arg("--agent-pubkey-file")
        .arg(destination.join("agent.pub"))
        .output()
        .unwrap();
    assert!(output.status.success());
    fs::copy(&host, destination.join("host.key")).unwrap();
    fs::copy(&agent, destination.join("agent.pub")).unwrap();
    write_file_with_mode(
        &destination.join("config.toml"),
        &String::from_utf8(output.stdout).unwrap(),
        0o644,
    );
    fs::remove_dir_all(source_dir).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request = read_request(&mut stream);
        let response = AuthResponseBody::for_request(
            &request.body,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            request.body.created_at_ms,
            request.body.expires_at_ms,
            "agent",
        )
        .unwrap()
        .sign(&SigningKey::from_bytes(&[9; 32]))
        .unwrap();
        send_bytes(&mut stream, &serde_json::to_vec(&response).unwrap());
    });
    let output = Command::new(env!("CARGO_BIN_EXE_macos-auth-helper"))
        .args(["request", "--config"])
        .arg(destination.join("config.toml"))
        .args(["--user", "alice"])
        .output()
        .unwrap();
    server.join().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    fs::remove_file(socket).unwrap();
    fs::remove_dir_all(directory).unwrap();
}
