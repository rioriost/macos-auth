# macos-auth

`macos-auth` is an experimental PAM module plus macOS user-session agent for approving Linux `sudo` authentication over SSH with Apple Watch / Touch ID on the user's Mac.

> **Status:** development-only. Do not use this as a production authentication mechanism yet.

## What this project is trying to do

The target flow is:

1. You SSH from macOS into a Linux host.
2. You run `sudo` on Linux.
3. Linux PAM invokes `pam_macos_auth.so`.
4. The PAM shim invokes `macos-auth-helper`.
5. The helper sends a signed request over an SSH-forwarded Unix socket.
6. The macOS agent verifies the Linux host signature and host allowlist.
7. The macOS agent shows request context and asks for Apple Watch / Touch ID approval through `LocalAuthentication.framework`.
8. The macOS agent returns a signed response.
9. The Linux helper verifies the response and maps it to PAM success, password fallback, or hard fail.

## Security model summary

The design is based on these properties:

- SSH forwarding is transport only, not a trust boundary.
- Linux requests are signed by a root-owned host key.
- macOS responses are signed by a pinned agent key.
- Nonces, timestamps, and request hashes prevent response substitution and limit replay risk.
- The macOS agent verifies host signatures before showing any UI.
- Authenticator unavailability falls back to normal Linux password authentication.
- Tampering, invalid signatures, binding mismatch, protocol errors, and unsafe config fail closed.
- The macOS agent must not expose a generic signing API.

Read these before testing:

- `SECURITY.md`
- `docs/security-hardening.md`
- `docs/threat-model.md`
- `docs/fallback-policy.md`
- `docs/known-bad-configurations.md`

## Components

| Component | Path | Purpose |
|---|---|---|
| Protocol crate | `crates/protocol` | Signed request/response types, canonical bytes, signature verification |
| Linux helper | `crates/helper` | Generates signed PAM requests, talks to agent socket, verifies responses |
| PAM shim | `pam/pam_macos_auth.c` | Extracts PAM context, invokes helper, maps helper exit codes to PAM results |
| macOS agent | `agent` | Verifies Linux requests, shows confirmation UI, invokes LocalAuthentication, signs responses |
| LaunchAgent files | `agent/launchd`, `scripts/install-launchagent.sh` | macOS user-session startup |
| Development scripts | `scripts/*dev*.sh` | Generate local development configs and install test artifacts |

## Current implementation status

Implemented:

- Rust protocol implementation with deterministic canonical signing bytes
- Rust helper CLI
- Linux helper config/key permission checks
- Rust fake agent for integration tests
- C PAM shim with helper timeout and sanitized `execve`
- Swift macOS agent with:
  - `fake-agent`
  - `serve`
  - `LocalAuthentication.framework`
  - confirmation UI
  - host allowlist
  - in-memory rate limiting
  - Keychain generic-password development key storage
  - host allowlist management commands
- LaunchAgent template and install/uninstall/status scripts
- Development setup scripts for Linux and macOS
- PAM testing guide with `pamtester`
- Deterministic protocol v1 test vector verified by both Rust and Swift
- Local quality gate through `make check` / `scripts/check.sh`

Not production-ready:

- Agent key storage is not yet Secure Enclave non-exportable.
- PAM flow still needs Linux VM / distro end-to-end testing.
- Installer scripts are development-oriented.
- Confirmation UI is a basic `NSAlert`.
- No external security review has been performed.

## Quick development flow

### 1. Build and check

```text
make check
```

Equivalent:

```text
scripts/check.sh
```

### 2. Create macOS agent public key

```text
swift build --package-path agent
agent/.build/debug/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default \
  --overwrite
agent/.build/debug/macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default > ./agent_ed25519.pub
```

### 3. Create Linux-side development config

```text
cargo build
scripts/linux-dev-setup.sh \
  --host-id linux-host-id \
  --hostname linux.example.com \
  --agent-pubkey-file ./agent_ed25519.pub \
  --force
```

This creates `./macos-auth-linux-dev/host_ed25519.pub`, which must be allowed by the macOS agent.

### 4. Create macOS-side development config

```text
scripts/macos-dev-setup.sh \
  --host-id linux-host-id \
  --host-pubkey-file ./macos-auth-linux-dev/host_ed25519.pub
```

### 5. Run macOS agent manually

```text
"$HOME/.local/bin/macos-auth-agent" serve \
  --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

### 6. Test Linux helper directly

```text
target/debug/macos-auth-helper request \
  --config ./macos-auth-linux-dev/config.toml \
  --user "$USER" \
  --ruser "$USER" \
  --tty pts/3
```

For full setup details, see `docs/development-e2e.md`.

## PAM testing

Do **not** edit `/etc/pam.d/sudo` first.

Use the test service and `pamtester` flow in:

- `docs/pam-testing.md`
- `pam/examples/macos-auth-test`

Recommended PAM control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
```

This means:

- macOS approval succeeds immediately
- authenticator unavailable/cancel/failure falls back to password
- tampering/unsafe config/protocol errors hard fail

## SSH transport

Use SSH `RemoteForward` for the Unix socket transport. Do not use generic SSH agent forwarding.

Example:

```text
Host linux-with-macos-auth
    HostName linux.example.com
    User alice
    RemoteForward /run/user/1000/macos-auth-agent.sock /Users/YOUR_MAC_USER/Library/Application Support/macos-auth/agent.sock
    StreamLocalBindUnlink yes
    ExitOnForwardFailure yes
```

See `docs/ssh-transport.md` for details.

## Documentation index

| Document | Purpose |
|---|---|
| `implementation_plan.md` | Original implementation plan and rationale |
| `SECURITY.md` | Security policy and current security status |
| `docs/security-hardening.md` | Hardening checklist |
| `docs/threat-model.md` | Threat model |
| `docs/fallback-policy.md` | Fallback vs hard-fail semantics |
| `docs/ssh-transport.md` | SSH forwarding assumptions and configuration |
| `docs/known-bad-configurations.md` | Unsafe configurations to avoid |
| `docs/macos-local-authentication.md` | Apple Watch / Touch ID / LocalAuthentication notes |
| `docs/keychain-and-secure-enclave.md` | Keychain and Secure Enclave notes |
| `docs/protocol-v2-p256.md` | Feasibility note for future P-256 / Secure Enclave protocol support |
| `docs/release-packaging.md` | Release packaging plan for Linux and macOS artifacts |
| `docs/build-farm.md` | Local/native build farm policy and builder roles |
| `docs/development-e2e.md` | Development end-to-end setup |
| `docs/linux-vm-test-plan.md` | Manual Parallels VM test plan for Ubuntu/Debian and Fedora/RHEL |
| `docs/pam-testing.md` | PAM testing guide |
| `docs/protocol.md` | Protocol notes and test vectors |
| `docs/frame-transport.md` | Current length-prefixed JSON frame transport specification |
| `docs/fuzzing.md` | Fuzzing setup and targets |
| `docs/helper.md` | Linux helper usage |
| `agent/README.md` | macOS agent usage |
| `pam/README.md` | PAM shim usage |

## Quality gate

Run before committing:

```text
make check
```

This runs:

- Rust formatting check
- Rust tests
- Swift build
- Swift protocol vector verification
- PAM C syntax check
- shell script syntax checks

## License

MIT. See `LICENSE`.
