use std::fs;
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand, ValueEnum};
use ed25519_dalek::SigningKey;
use macos_auth_protocol::{
    AuthMethod, AuthRequestBody, AuthResponseBody, Decision, SignatureAlgorithm, SignedAuthRequest,
    SignedAuthResponse, NONCE_LEN, PROTOCOL_VERSION,
};
use rand_core::{OsRng, RngCore};
use serde::Deserialize;
use sha2::{Digest, Sha256};

const EXIT_APPROVED: i32 = 0;
const EXIT_UNAVAILABLE: i32 = 10;
const EXIT_CANCELLED: i32 = 11;
const EXIT_FAILED: i32 = 12;
const EXIT_DENIED: i32 = 20;
const EXIT_TAMPER: i32 = 30;
const EXIT_UNSAFE_CONFIG: i32 = 31;
const EXIT_PROTOCOL: i32 = 32;

const MAX_FRAME_LEN: usize = 1024 * 1024;

#[derive(Debug, Parser)]
#[command(name = "macos-auth-helper")]
#[command(about = "Linux-side helper for macos-auth PAM integration")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Generate an Ed25519 keypair and print it as hex.
    GenKey {
        /// Write the private key hex to this file with mode 0600.
        #[arg(long)]
        private_key_file: Option<PathBuf>,
        /// Write the public key hex to this file with mode 0644.
        #[arg(long)]
        public_key_file: Option<PathBuf>,
    },
    /// Derive an Ed25519 public key from a private key hex string or file.
    Pubkey(KeyInputArgs),
    /// Emit a signed sample auth request as JSON for protocol testing.
    SampleRequest(RequestFixtureArgs),
    /// Emit a signed sample approval response for a generated request.
    SampleResponse,
    /// Emit the deterministic protocol v1 test vector.
    TestVector,
    /// Send a signed request to an agent socket and verify the signed response.
    Request(RequestArgs),
    /// Run a local fake agent for integration testing.
    FakeAgent(FakeAgentArgs),
}

#[derive(Debug, Parser)]
struct RequestFixtureArgs {
    #[command(flatten)]
    key_input: OptionalKeyInputArgs,
    #[arg(long, default_value = "host-key-1")]
    key_id: String,
    #[arg(long, default_value = "host-abc")]
    host_id: String,
    #[arg(long, default_value = "linux.example.com")]
    hostname: String,
    #[arg(long, default_value = "sudo")]
    service: String,
    #[arg(long, default_value = "alice")]
    user: String,
    #[arg(long)]
    ruser: Option<String>,
    #[arg(long)]
    rhost: Option<String>,
    #[arg(long)]
    tty: Option<String>,
    #[arg(long)]
    sudo_command: Option<String>,
}

#[derive(Debug, Parser)]
struct RequestArgs {
    /// TOML config file. CLI arguments override config values.
    #[arg(long)]
    config: Option<PathBuf>,
    /// Unix domain socket path forwarded to the macOS agent.
    #[arg(long)]
    socket: Option<PathBuf>,
    #[command(flatten)]
    key_input: KeyInputArgs,
    #[command(flatten)]
    agent_pubkey_input: AgentPublicKeyInputArgs,
    #[arg(long)]
    key_id: Option<String>,
    #[arg(long)]
    host_id: Option<String>,
    #[arg(long)]
    hostname: Option<String>,
    #[arg(long)]
    service: Option<String>,
    #[arg(long)]
    user: String,
    #[arg(long)]
    ruser: Option<String>,
    #[arg(long)]
    rhost: Option<String>,
    #[arg(long)]
    tty: Option<String>,
    #[arg(long)]
    sudo_command: Option<String>,
    #[arg(long)]
    timeout_ms: Option<u64>,
    #[arg(long)]
    allowed_future_skew_ms: Option<u64>,
    /// Optional root-owned replay cache directory.
    #[arg(long)]
    replay_cache_dir: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct KeyInputArgs {
    /// Ed25519 private key hex. Development only; prefer --key-file.
    #[arg(long, conflicts_with = "key_file")]
    key_hex: Option<String>,
    /// Ed25519 private key hex file. Must be a regular file with no group/world permissions.
    #[arg(long)]
    key_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct OptionalKeyInputArgs {
    /// Ed25519 private key hex. If omitted with --key-file, an ephemeral key is generated and printed to stderr.
    #[arg(long, conflicts_with = "key_file")]
    key_hex: Option<String>,
    /// Ed25519 private key hex file.
    #[arg(long)]
    key_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct AgentPublicKeyInputArgs {
    /// Pinned macOS agent Ed25519 public key hex.
    #[arg(long, conflicts_with = "agent_pubkey_file")]
    agent_pubkey_hex: Option<String>,
    /// Pinned macOS agent Ed25519 public key hex file.
    #[arg(long)]
    agent_pubkey_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct HostPublicKeyInputArgs {
    /// Pinned Linux host Ed25519 public key hex.
    #[arg(long, conflicts_with = "host_pubkey_file")]
    host_pubkey_hex: Option<String>,
    /// Pinned Linux host Ed25519 public key hex file.
    #[arg(long)]
    host_pubkey_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct AgentKeyInputArgs {
    /// Fake macOS agent Ed25519 private key hex.
    #[arg(long, conflicts_with = "agent_key_file")]
    agent_key_hex: Option<String>,
    /// Fake macOS agent Ed25519 private key hex file.
    #[arg(long)]
    agent_key_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct FakeAgentArgs {
    /// Unix domain socket path to listen on.
    #[arg(long)]
    socket: PathBuf,
    #[command(flatten)]
    host_pubkey_input: HostPublicKeyInputArgs,
    #[command(flatten)]
    agent_key_input: AgentKeyInputArgs,
    #[arg(long, default_value = "agent-key-1")]
    agent_key_id: String,
    #[arg(long, value_enum, default_value_t = CliDecision::Approved)]
    decision: CliDecision,
    /// Exit after one request. Useful for tests.
    #[arg(long)]
    once: bool,
}

#[derive(Debug, Default, Deserialize)]
struct HelperConfig {
    socket_path: Option<PathBuf>,
    host_key_file: Option<PathBuf>,
    agent_pubkey_file: Option<PathBuf>,
    key_id: Option<String>,
    host_id: Option<String>,
    hostname: Option<String>,
    service: Option<String>,
    timeout_ms: Option<u64>,
    allowed_future_skew_ms: Option<u64>,
    replay_cache_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum CliDecision {
    Approved,
    Denied,
    Unavailable,
    Cancelled,
    Failed,
}

impl From<CliDecision> for Decision {
    fn from(value: CliDecision) -> Self {
        match value {
            CliDecision::Approved => Decision::Approved,
            CliDecision::Denied => Decision::Denied,
            CliDecision::Unavailable => Decision::Unavailable,
            CliDecision::Cancelled => Decision::Cancelled,
            CliDecision::Failed => Decision::Failed,
        }
    }
}

fn main() {
    match run() {
        Ok(Some(exit_code)) => std::process::exit(exit_code),
        Ok(None) => {}
        Err(error) => {
            eprintln!("macos-auth-helper: {error}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<Option<i32>, Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    match cli.command {
        Command::GenKey {
            private_key_file,
            public_key_file,
        } => {
            let signing_key = SigningKey::generate(&mut OsRng);
            if let Some(path) = private_key_file {
                write_private_key_file(&path, &hex::encode(signing_key.to_bytes()))?;
            }
            if let Some(path) = public_key_file {
                write_public_key_file(&path, &hex::encode(signing_key.verifying_key().to_bytes()))?;
            }
            print_keypair(&signing_key);
            Ok(None)
        }
        Command::Pubkey(args) => {
            let signing_key =
                load_required_signing_key(args.key_hex.as_deref(), args.key_file.as_deref())?;
            println!(
                "public_key_hex={}",
                hex::encode(signing_key.verifying_key().to_bytes())
            );
            Ok(None)
        }
        Command::SampleRequest(args) => {
            let signing_key = load_optional_signing_key(
                args.key_input.key_hex.as_deref(),
                args.key_input.key_file.as_deref(),
            )?;
            if args.key_input.key_hex.is_none() && args.key_input.key_file.is_none() {
                eprintln!(
                    "ephemeral_private_key_hex={}",
                    hex::encode(signing_key.to_bytes())
                );
                eprintln!(
                    "ephemeral_public_key_hex={}",
                    hex::encode(signing_key.verifying_key().to_bytes())
                );
            }

            let now = unix_time_ms()?;
            let request = build_request(now, args.into_context())?;
            let signed = request.sign(&signing_key)?;
            println!("{}", serde_json::to_string_pretty(&signed)?);
            Ok(None)
        }
        Command::SampleResponse => {
            let host_key = SigningKey::generate(&mut OsRng);
            let agent_key = SigningKey::generate(&mut OsRng);
            let now = unix_time_ms()?;
            let request = build_request(now, RequestContext::sample())?.sign(&host_key)?;

            let response = AuthResponseBody::for_request(
                &request.body,
                Decision::Approved,
                AuthMethod::BiometricOrWatch,
                now + 1_000,
                now + 11_000,
                "agent-key-1",
            )?
            .sign(&agent_key)?;

            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "host_public_key_hex": hex::encode(host_key.verifying_key().to_bytes()),
                    "agent_public_key_hex": hex::encode(agent_key.verifying_key().to_bytes()),
                    "request": request,
                    "response": response,
                }))?
            );
            Ok(None)
        }
        Command::TestVector => {
            println!("{}", serde_json::to_string_pretty(&build_test_vector()?)?);
            Ok(None)
        }
        Command::Request(args) => Ok(Some(run_request(args)?)),
        Command::FakeAgent(args) => {
            run_fake_agent(args)?;
            Ok(None)
        }
    }
}

fn build_test_vector() -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let host_key = SigningKey::from_bytes(&[0x07; 32]);
    let agent_key = SigningKey::from_bytes(&[0x09; 32]);
    let request = AuthRequestBody {
        protocol_version: PROTOCOL_VERSION,
        request_id: "req-test-vector-v1".to_string(),
        nonce: vec![0x42; NONCE_LEN],
        created_at_ms: 1_700_000_000_000,
        expires_at_ms: 1_700_000_030_000,
        linux_host_id: "host-abc".to_string(),
        linux_hostname: "linux.example.com".to_string(),
        pam_service: "sudo".to_string(),
        pam_user: "alice".to_string(),
        pam_ruser: Some("alice".to_string()),
        pam_rhost: None,
        pam_tty: Some("pts/3".to_string()),
        sudo_command: Some("/usr/bin/id".to_string()),
        client_pid: Some(12345),
        key_id: "host-key-1".to_string(),
        alg: SignatureAlgorithm::Ed25519,
    };
    let signed_request = request.sign(&host_key)?;
    let response = AuthResponseBody::for_request(
        &signed_request.body,
        Decision::Approved,
        AuthMethod::BiometricOrWatch,
        1_700_000_001_000,
        1_700_000_011_000,
        "agent-key-1",
    )?;
    let request_hash_hex = hex::encode(signed_request.body.sha256()?);
    let signed_response = response.sign(&agent_key)?;

    Ok(serde_json::json!({
        "name": "macos-auth protocol v1 deterministic approval vector",
        "host_private_key_hex": hex::encode(host_key.to_bytes()),
        "host_public_key_hex": hex::encode(host_key.verifying_key().to_bytes()),
        "agent_private_key_hex": hex::encode(agent_key.to_bytes()),
        "agent_public_key_hex": hex::encode(agent_key.verifying_key().to_bytes()),
        "request_hash_hex": request_hash_hex,
        "request": signed_request,
        "response": signed_response,
    }))
}

impl RequestFixtureArgs {
    fn into_context(self) -> RequestContext {
        RequestContext {
            key_id: self.key_id,
            host_id: self.host_id,
            hostname: self.hostname,
            service: self.service,
            user: self.user,
            ruser: self.ruser,
            rhost: self.rhost,
            tty: self.tty,
            sudo_command: self.sudo_command,
        }
    }
}

fn run_request(args: RequestArgs) -> Result<i32, Box<dyn std::error::Error>> {
    let config = match load_helper_config(args.config.as_deref()) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("unsafe or invalid config: failed to load config: {error}");
            return Ok(EXIT_UNSAFE_CONFIG);
        }
    };

    let host_key_file = args
        .key_input
        .key_file
        .as_deref()
        .or(config.host_key_file.as_deref());
    let signing_key =
        match load_required_signing_key(args.key_input.key_hex.as_deref(), host_key_file) {
            Ok(signing_key) => signing_key,
            Err(error) => {
                eprintln!("unsafe or invalid config: failed to load host private key: {error}");
                return Ok(EXIT_UNSAFE_CONFIG);
            }
        };

    let agent_pubkey_file = args
        .agent_pubkey_input
        .agent_pubkey_file
        .as_deref()
        .or(config.agent_pubkey_file.as_deref());
    let agent_pubkey = match load_required_public_key(
        args.agent_pubkey_input.agent_pubkey_hex.as_deref(),
        agent_pubkey_file,
        "agent public key",
    ) {
        Ok(agent_pubkey) => agent_pubkey,
        Err(error) => {
            eprintln!("unsafe or invalid config: failed to load agent public key: {error}");
            return Ok(EXIT_UNSAFE_CONFIG);
        }
    };

    let socket = match args.socket.or(config.socket_path) {
        Some(socket) => socket,
        None => {
            eprintln!("unsafe or invalid config: missing socket path; provide --socket or socket_path in config");
            return Ok(EXIT_UNSAFE_CONFIG);
        }
    };
    let key_id = args
        .key_id
        .or(config.key_id)
        .unwrap_or_else(|| "host-key-1".to_string());
    let host_id = match args.host_id.or(config.host_id) {
        Some(host_id) => host_id,
        None => {
            eprintln!(
                "unsafe or invalid config: missing host id; provide --host-id or host_id in config"
            );
            return Ok(EXIT_UNSAFE_CONFIG);
        }
    };
    let hostname = match args.hostname.or(config.hostname) {
        Some(hostname) => hostname,
        None => {
            eprintln!("unsafe or invalid config: missing hostname; provide --hostname or hostname in config");
            return Ok(EXIT_UNSAFE_CONFIG);
        }
    };
    let service = args
        .service
        .or(config.service)
        .unwrap_or_else(|| "sudo".to_string());
    let timeout_ms = args.timeout_ms.or(config.timeout_ms).unwrap_or(15_000);
    let allowed_future_skew_ms = args
        .allowed_future_skew_ms
        .or(config.allowed_future_skew_ms)
        .unwrap_or(30_000);
    let replay_cache_dir = args.replay_cache_dir.or(config.replay_cache_dir);

    let now = unix_time_ms()?;
    let request = build_request(
        now,
        RequestContext {
            key_id,
            host_id,
            hostname,
            service,
            user: args.user,
            ruser: args.ruser,
            rhost: args.rhost,
            tty: args.tty,
            sudo_command: args.sudo_command,
        },
    )?
    .sign(&signing_key)?;

    let timeout = Duration::from_millis(timeout_ms);
    let mut stream = match UnixStream::connect(&socket) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!(
                "agent unavailable: failed to connect to {}: {error}",
                socket.display()
            );
            return Ok(EXIT_UNAVAILABLE);
        }
    };
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;

    if let Err(error) = write_json_frame(&mut stream, &request) {
        eprintln!("protocol error: failed to write request: {error}");
        return Ok(EXIT_PROTOCOL);
    }

    let response: SignedAuthResponse = match read_json_frame(&mut stream) {
        Ok(response) => response,
        Err(error) => {
            eprintln!("protocol error: failed to read response: {error}");
            return Ok(EXIT_PROTOCOL);
        }
    };

    if let Err(error) = response.verify_for_request(&request.body, &agent_pubkey) {
        eprintln!("tamper detected: response verification failed: {error}");
        return Ok(EXIT_TAMPER);
    }

    let now = unix_time_ms()?;
    if let Err(error) = response.body.verify_freshness(now, allowed_future_skew_ms) {
        eprintln!("tamper detected: response freshness check failed: {error}");
        return Ok(EXIT_TAMPER);
    }

    if let Some(replay_cache_dir) = replay_cache_dir.as_deref() {
        if let Err(error) = record_replay_marker(replay_cache_dir, &response) {
            eprintln!("tamper detected: replay cache rejected response: {error}");
            return Ok(EXIT_TAMPER);
        }
    }

    Ok(exit_code_for_decision(response.body.decision))
}

fn run_fake_agent(args: FakeAgentArgs) -> Result<(), Box<dyn std::error::Error>> {
    remove_stale_socket(&args.socket)?;
    let listener = UnixListener::bind(&args.socket)?;
    let host_pubkey = load_required_public_key(
        args.host_pubkey_input.host_pubkey_hex.as_deref(),
        args.host_pubkey_input.host_pubkey_file.as_deref(),
        "host public key",
    )?;
    let agent_key = load_required_signing_key(
        args.agent_key_input.agent_key_hex.as_deref(),
        args.agent_key_input.agent_key_file.as_deref(),
    )?;
    let decision = Decision::from(args.decision);

    eprintln!("fake agent listening on {}", args.socket.display());

    loop {
        let (mut stream, _) = listener.accept()?;
        let request: SignedAuthRequest = match read_json_frame(&mut stream) {
            Ok(request) => request,
            Err(error) => {
                eprintln!("fake agent: failed to read request: {error}");
                if args.once {
                    break;
                }
                continue;
            }
        };

        if let Err(error) = request.verify(&host_pubkey) {
            eprintln!("fake agent: rejecting invalid request signature: {error}");
            if args.once {
                break;
            }
            continue;
        }

        let now = unix_time_ms()?;
        if let Err(error) = request.body.verify_freshness(now, 30_000) {
            eprintln!("fake agent: rejecting stale request: {error}");
            if args.once {
                break;
            }
            continue;
        }

        let auth_method = if decision == Decision::Approved {
            AuthMethod::BiometricOrWatch
        } else {
            AuthMethod::None
        };
        let response = AuthResponseBody::for_request(
            &request.body,
            decision,
            auth_method,
            now,
            now + 10_000,
            &args.agent_key_id,
        )?
        .sign(&agent_key)?;

        if let Err(error) = write_json_frame(&mut stream, &response) {
            eprintln!("fake agent: failed to write response: {error}");
        }

        if args.once {
            break;
        }
    }

    let _ = fs::remove_file(&args.socket);
    Ok(())
}

#[derive(Debug)]
struct RequestContext {
    key_id: String,
    host_id: String,
    hostname: String,
    service: String,
    user: String,
    ruser: Option<String>,
    rhost: Option<String>,
    tty: Option<String>,
    sudo_command: Option<String>,
}

impl RequestContext {
    fn sample() -> Self {
        Self {
            key_id: "host-key-1".to_string(),
            host_id: "host-abc".to_string(),
            hostname: "linux.example.com".to_string(),
            service: "sudo".to_string(),
            user: "alice".to_string(),
            ruser: Some("alice".to_string()),
            rhost: None,
            tty: Some("pts/3".to_string()),
            sudo_command: None,
        }
    }
}

fn build_request(
    now_ms: u64,
    context: RequestContext,
) -> Result<AuthRequestBody, Box<dyn std::error::Error>> {
    let mut nonce = vec![0_u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);

    Ok(AuthRequestBody {
        protocol_version: PROTOCOL_VERSION,
        request_id: format!("req-{now_ms}-{}", std::process::id()),
        nonce,
        created_at_ms: now_ms,
        expires_at_ms: now_ms + 30_000,
        linux_host_id: context.host_id,
        linux_hostname: context.hostname,
        pam_service: context.service,
        pam_user: context.user,
        pam_ruser: context.ruser,
        pam_rhost: context.rhost,
        pam_tty: context.tty,
        sudo_command: context.sudo_command,
        client_pid: Some(std::process::id()),
        key_id: context.key_id,
        alg: SignatureAlgorithm::Ed25519,
    })
}

fn print_keypair(signing_key: &SigningKey) {
    println!("private_key_hex={}", hex::encode(signing_key.to_bytes()));
    println!(
        "public_key_hex={}",
        hex::encode(signing_key.verifying_key().to_bytes())
    );
}

fn load_helper_config(path: Option<&Path>) -> Result<HelperConfig, Box<dyn std::error::Error>> {
    let Some(path) = path else {
        return Ok(HelperConfig::default());
    };
    validate_config_file_permissions(path)?;
    let contents = fs::read_to_string(path)?;
    Ok(toml::from_str(&contents)?)
}

fn validate_config_file_permissions(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let metadata = fs::metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(format!("config path {} is not a regular file", path.display()).into());
    }
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o022 != 0 {
        return Err(format!(
            "config file {} must not be group/world writable; mode is {:o}",
            path.display(),
            mode
        )
        .into());
    }
    Ok(())
}

fn load_optional_signing_key(
    key_hex: Option<&str>,
    key_file: Option<&Path>,
) -> Result<SigningKey, Box<dyn std::error::Error>> {
    match (key_hex, key_file) {
        (Some(key_hex), None) => signing_key_from_hex(key_hex),
        (None, Some(path)) => signing_key_from_file(path),
        (None, None) => Ok(SigningKey::generate(&mut OsRng)),
        (Some(_), Some(_)) => Err("provide only one of --key-hex or --key-file".into()),
    }
}

fn load_required_signing_key(
    key_hex: Option<&str>,
    key_file: Option<&Path>,
) -> Result<SigningKey, Box<dyn std::error::Error>> {
    match (key_hex, key_file) {
        (Some(key_hex), None) => signing_key_from_hex(key_hex),
        (None, Some(path)) => signing_key_from_file(path),
        (None, None) => Err("missing private key; provide --key-hex or --key-file".into()),
        (Some(_), Some(_)) => Err("provide only one of --key-hex or --key-file".into()),
    }
}

fn signing_key_from_file(path: &Path) -> Result<SigningKey, Box<dyn std::error::Error>> {
    validate_private_key_file_permissions(path)?;
    let material = read_key_material(path)?;
    signing_key_from_hex(&material)
}

fn signing_key_from_hex(key_hex: &str) -> Result<SigningKey, Box<dyn std::error::Error>> {
    let key_bytes = hex::decode(key_hex.trim())?;
    let key_bytes: [u8; 32] = key_bytes
        .try_into()
        .map_err(|_| "Ed25519 private key must be exactly 32 bytes")?;
    Ok(SigningKey::from_bytes(&key_bytes))
}

fn load_required_public_key(
    key_hex: Option<&str>,
    key_file: Option<&Path>,
    label: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let material = match (key_hex, key_file) {
        (Some(key_hex), None) => key_hex.trim().to_string(),
        (None, Some(path)) => {
            validate_public_key_file_permissions(path)?;
            read_key_material(path)?
        }
        (None, None) => return Err(format!("missing {label}; provide hex or file").into()),
        (Some(_), Some(_)) => return Err(format!("provide only one {label} source").into()),
    };
    let bytes = hex::decode(material)?;
    if bytes.len() != 32 {
        return Err(format!("{label} must be exactly 32 bytes").into());
    }
    Ok(bytes)
}

fn read_key_material(path: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let contents = fs::read_to_string(path)?;
    for raw_line in contents.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((_, value)) = line.split_once('=') {
            return Ok(value.trim().to_string());
        }
        return Ok(line.to_string());
    }
    Err(format!("key file {} does not contain key material", path.display()).into())
}

fn validate_private_key_file_permissions(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let metadata = fs::metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(format!("private key path {} is not a regular file", path.display()).into());
    }
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(format!(
            "private key file {} must not grant group/world permissions; mode is {:o}",
            path.display(),
            mode
        )
        .into());
    }
    Ok(())
}

fn validate_public_key_file_permissions(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let metadata = fs::metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(format!("public key path {} is not a regular file", path.display()).into());
    }
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o022 != 0 {
        return Err(format!(
            "public key file {} must not be group/world writable; mode is {:o}",
            path.display(),
            mode
        )
        .into());
    }
    Ok(())
}

fn write_private_key_file(
    path: &Path,
    private_key_hex: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    writeln!(file, "private_key_hex={private_key_hex}")?;
    Ok(())
}

fn write_public_key_file(
    path: &Path,
    public_key_hex: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .open(path)?;
    writeln!(file, "public_key_hex={public_key_hex}")?;
    Ok(())
}

fn record_replay_marker(
    replay_cache_dir: &Path,
    response: &SignedAuthResponse,
) -> Result<(), Box<dyn std::error::Error>> {
    validate_replay_cache_dir(replay_cache_dir)?;
    cleanup_replay_cache(replay_cache_dir)?;
    let signature_hash = Sha256::digest(&response.signature);
    let marker_name = hex::encode(signature_hash);
    let marker_path = replay_cache_dir.join(marker_name);
    let mut file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&marker_path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            return Err("response replay detected".into());
        }
        Err(error) => return Err(Box::new(error)),
    };
    writeln!(file, "expires_at_ms={}", response.body.expires_at_ms)?;
    Ok(())
}

fn validate_replay_cache_dir(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let metadata = fs::metadata(path)?;
    if !metadata.file_type().is_dir() {
        return Err(format!("replay cache path {} is not a directory", path.display()).into());
    }
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(format!(
            "replay cache directory {} must not grant group/world permissions; mode is {:o}",
            path.display(),
            mode
        )
        .into());
    }
    Ok(())
}

fn cleanup_replay_cache(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let now = unix_time_ms()?;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let contents = match fs::read_to_string(entry.path()) {
            Ok(contents) => contents,
            Err(_) => continue,
        };
        let Some(expires_at_ms) = parse_expires_at_ms(&contents) else {
            continue;
        };
        if expires_at_ms < now {
            let _ = fs::remove_file(entry.path());
        }
    }
    Ok(())
}

fn parse_expires_at_ms(contents: &str) -> Option<u64> {
    for line in contents.lines() {
        let line = line.trim();
        let value = line.strip_prefix("expires_at_ms=")?;
        return value.parse::<u64>().ok();
    }
    None
}

fn exit_code_for_decision(decision: Decision) -> i32 {
    match decision {
        Decision::Approved => EXIT_APPROVED,
        Decision::Denied => EXIT_DENIED,
        Decision::Unavailable => EXIT_UNAVAILABLE,
        Decision::Cancelled => EXIT_CANCELLED,
        Decision::Failed => EXIT_FAILED,
    }
}

fn write_json_frame<T: serde::Serialize>(
    stream: &mut UnixStream,
    value: &T,
) -> Result<(), Box<dyn std::error::Error>> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() > MAX_FRAME_LEN {
        return Err(format!("frame too large: {} bytes", bytes.len()).into());
    }
    let frame_len = u32::try_from(bytes.len())?;
    stream.write_all(&frame_len.to_be_bytes())?;
    stream.write_all(&bytes)?;
    Ok(())
}

fn read_json_frame<T: serde::de::DeserializeOwned>(
    stream: &mut UnixStream,
) -> Result<T, Box<dyn std::error::Error>> {
    let mut len_bytes = [0_u8; 4];
    stream.read_exact(&mut len_bytes)?;
    let len = u32::from_be_bytes(len_bytes) as usize;
    if len > MAX_FRAME_LEN {
        return Err(format!("frame too large: {len} bytes").into());
    }
    let mut bytes = vec![0_u8; len];
    stream.read_exact(&mut bytes)?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn remove_stale_socket(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(Box::new(error)),
    }
}

fn unix_time_ms() -> Result<u64, Box<dyn std::error::Error>> {
    let duration = SystemTime::now().duration_since(UNIX_EPOCH)?;
    Ok(duration.as_millis().try_into()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_raw_frame(stream: &mut UnixStream, payload: &[u8]) {
        let len = u32::try_from(payload.len()).unwrap();
        stream.write_all(&len.to_be_bytes()).unwrap();
        stream.write_all(payload).unwrap();
        stream.shutdown(std::net::Shutdown::Write).unwrap();
    }

    fn sample_signed_response() -> SignedAuthResponse {
        let agent_key = SigningKey::from_bytes(&[0x09; 32]);
        let request = AuthRequestBody {
            protocol_version: PROTOCOL_VERSION,
            request_id: "req-replay-test".to_string(),
            nonce: vec![0x42; NONCE_LEN],
            created_at_ms: 1_700_000_000_000,
            expires_at_ms: 4_102_444_800_000,
            linux_host_id: "host-abc".to_string(),
            linux_hostname: "linux.example.com".to_string(),
            pam_service: "sudo".to_string(),
            pam_user: "alice".to_string(),
            pam_ruser: Some("alice".to_string()),
            pam_rhost: None,
            pam_tty: Some("pts/3".to_string()),
            sudo_command: None,
            client_pid: Some(12345),
            key_id: "host-key-1".to_string(),
            alg: SignatureAlgorithm::Ed25519,
        };
        AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            4_102_444_800_000,
            "agent-key-1",
        )
        .unwrap()
        .sign(&agent_key)
        .unwrap()
    }

    fn unique_test_dir(label: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_micros();
        std::env::temp_dir().join(format!("macos-auth-{label}-{}-{now}", std::process::id()))
    }

    #[test]
    fn frame_reader_rejects_oversized_frame() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        let len = u32::try_from(MAX_FRAME_LEN + 1).unwrap();
        writer.write_all(&len.to_be_bytes()).unwrap();
        writer.shutdown(std::net::Shutdown::Write).unwrap();

        let result: Result<serde_json::Value, _> = read_json_frame(&mut reader);
        assert!(result.unwrap_err().to_string().contains("frame too large"));
    }

    #[test]
    fn frame_reader_rejects_truncated_length() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        writer.write_all(&[0_u8, 1_u8]).unwrap();
        writer.shutdown(std::net::Shutdown::Write).unwrap();

        let result: Result<serde_json::Value, _> = read_json_frame(&mut reader);
        assert!(result.is_err());
    }

    #[test]
    fn frame_reader_rejects_truncated_body() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        writer.write_all(&10_u32.to_be_bytes()).unwrap();
        writer.write_all(b"{}").unwrap();
        writer.shutdown(std::net::Shutdown::Write).unwrap();

        let result: Result<serde_json::Value, _> = read_json_frame(&mut reader);
        assert!(result.is_err());
    }

    #[test]
    fn frame_reader_rejects_invalid_json() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        write_raw_frame(&mut writer, b"not-json");

        let result: Result<serde_json::Value, _> = read_json_frame(&mut reader);
        assert!(result.is_err());
    }

    #[test]
    fn frame_reader_rejects_wrong_schema() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        write_raw_frame(&mut writer, b"{}");

        let result: Result<SignedAuthResponse, _> = read_json_frame(&mut reader);
        assert!(result.is_err());
    }

    #[test]
    fn frame_round_trip_json_value() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        let value = serde_json::json!({"hello":"world"});
        write_json_frame(&mut writer, &value).unwrap();
        writer.shutdown(std::net::Shutdown::Write).unwrap();

        let decoded: serde_json::Value = read_json_frame(&mut reader).unwrap();
        assert_eq!(decoded, value);
    }

    #[test]
    fn replay_cache_rejects_duplicate_response() {
        let dir = unique_test_dir("replay");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let response = sample_signed_response();

        record_replay_marker(&dir, &response).unwrap();
        let second = record_replay_marker(&dir, &response);
        assert!(second.unwrap_err().to_string().contains("replay"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn replay_cache_rejects_permissive_directory() {
        let dir = unique_test_dir("replay-perm");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        let response = sample_signed_response();

        let result = record_replay_marker(&dir, &response);
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("must not grant group/world"));
        let _ = fs::remove_dir_all(dir);
    }
}
