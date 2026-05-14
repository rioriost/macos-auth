# macos-auth

`macos-auth` is an experimental PAM module, Linux helper, and macOS user-session agent for approving Linux authentication requests from a Mac.

This public repository contains the Linux build and packaging subset, release packaging documentation, and user-facing setup notes. The macOS agent package is distributed as a signed/notarized release asset and Homebrew cask; the macOS agent source is not part of this public source subset yet.

Public Linux-side contents include:

- Rust protocol and Linux helper crates
- C PAM shim
- Linux package build scripts and package metadata
- Linux testing and packaging documentation

> **Status:** development-only. Do not use this as a production authentication mechanism yet.

## Prerequisites

You need two machines or VMs:

1. a **Mac** running the macOS user-session agent
2. a **Linux host** where you want to approve PAM authentication requests from the Mac

On macOS:

- Apple Silicon Mac is the currently tested target
- Touch ID or Apple Watch unlock configured for LocalAuthentication approval
- OpenSSH client
- Homebrew, if installing through the cask

On Linux:

- OpenSSH server
- a user account with sudo access
- a supported package target:
  - Ubuntu 24.04 / 25.10, `amd64` or `arm64`
  - RHEL 9 / 10 family, `x86_64` or `aarch64`
- `pamtester` is strongly recommended before touching `sudo` PAM configuration

Security and recovery prerequisites:

- test in a VM or disposable host first
- keep console access to the Linux machine
- keep a root shell open before editing any PAM file
- do not use this as a production authentication mechanism yet

## Environment

A typical setup has the Linux host connect back to a Unix-domain socket on your Mac through SSH `RemoteForward`.

The Linux package provides:

- `/usr/bin/macos-auth-helper`
- `pam_macos_auth.so`
- documentation and PAM examples

The macOS package/cask follows the Apple Silicon Homebrew prefix and provides:

- `/opt/homebrew/bin/macos-auth-agent`
- LaunchAgent helper scripts under `/opt/homebrew/share/macos-auth/scripts/`
- a LaunchAgent plist template
- sample config files under `/opt/homebrew/share/macos-auth/examples/`

Runtime state is intentionally user-controlled:

- macOS agent config: `$HOME/Library/Application Support/macos-auth/agent-config.json`
- macOS agent socket: commonly under `$HOME/Library/Application Support/macos-auth/agent.sock`
- Linux helper config: `/etc/macos-auth/config.toml`
- Linux host private key: `/etc/macos-auth/host_ed25519.key`
- pinned macOS agent public key: `/etc/macos-auth/agents.d/*.pub`
- macOS samples: `/opt/homebrew/share/macos-auth/examples/agent-config.json.example` and `/opt/homebrew/share/macos-auth/examples/ssh-config.sample`
- Linux samples: `/usr/share/macos-auth/examples/config.toml.sample` and `/usr/share/macos-auth/examples/ssh-config.sample`

## How it works

```text
+----------------------+                         +----------------------+
| Linux host           |                         | macOS user session   |
|                      |                         |                      |
|  user runs sudo      |                         |  macos-auth-agent    |
|        |             |                         |  LocalAuthentication |
|        v             |                         |  Touch ID / Watch    |
|  Linux PAM           |                         |          ^           |
|        |             |                         |          |           |
|        v             | signed request          |          |           |
|  pam_macos_auth.so   |-------------------------+----------+           |
|        |             | via SSH RemoteForward Unix socket                |
|        v             |                         |                      |
|  macos-auth-helper   | signed response         |                      |
|        |             |<-----------------------------------------------|
|        v             |                         |                      |
|  PAM result          |                         |                      |
|   - approved: success|                         |                      |
|   - unavailable:    |                         |                      |
|     password fallback                         |                      |
|   - tamper/unsafe:  |                         |                      |
|     hard fail       |                         |                      |
+----------------------+                         +----------------------+
```

Trust model summary:

- SSH forwarding is transport only; it is not the trust boundary.
- Linux requests are signed by a root-owned Linux host key.
- macOS responses are signed by a pinned agent key.
- The macOS agent verifies the Linux host signature before showing UI.
- Nonces, timestamps, and request hashes limit replay/substitution risk.
- Authenticator unavailable/cancel/failure can fall back to normal Linux password authentication.
- Invalid signatures, unsafe config, tampering, and protocol errors fail closed.

## How to install

### 1. Install the macOS agent `[macOS]`

Run this on **macOS**. When the Homebrew cask is available:

```text
brew install --cask rioriost/cask/macos-auth
```

The cask installs files under `/opt/homebrew`; it does **not** automatically create keys, host allowlists, or a LaunchAgent.

Prepare an agent key and config, then install the per-user LaunchAgent explicitly. The exact host allowlist setup depends on the Linux host key generated in the next step.

Useful installed commands:

```text
/opt/homebrew/bin/macos-auth-agent --help
/opt/homebrew/share/macos-auth/scripts/install-launchagent.sh --help
/opt/homebrew/share/macos-auth/scripts/status-launchagent.sh
/opt/homebrew/share/macos-auth/scripts/uninstall-launchagent.sh --help
```

### 2. Install the Linux package `[Linux]`

Run this on **Linux**. Download the package matching your Linux distribution family and architecture from the release assets.

Ubuntu/Debian example:

```text
sudo dpkg -i macos-auth_0.1.0_ubuntu24.04_arm64.deb
```

RHEL-family example:

```text
sudo rpm -Uvh macos-auth-0.1.0-1.rhel9.aarch64.rpm
```

Packages install the helper and PAM module, but they do **not** modify `/etc/pam.d/sudo`.

### 3. Pair the Mac and Linux host `[macOS + Linux]`

Run this on **Linux** to generate a Linux host key:

```text
sudo mkdir -p /etc/macos-auth/agents.d
sudo /usr/bin/macos-auth-helper gen-key \
  --private-key-file /etc/macos-auth/host_ed25519.key \
  --public-key-file /etc/macos-auth/host_ed25519.pub
```

Run this on **macOS** to initialize a macOS agent key:

```text
/opt/homebrew/bin/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default

/opt/homebrew/bin/macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default > agent.pub
```

Copy public keys to the opposite side:

- copy the Linux host public key, `/etc/macos-auth/host_ed25519.pub`, to the Mac host allowlist
- copy the macOS agent public key, `agent.pub`, to Linux as `/etc/macos-auth/agents.d/agent.pub`

On **macOS**, start from the installed sample if you prefer:

```text
cp /opt/homebrew/share/macos-auth/examples/agent-config.json.example \
  "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

Example macOS agent config:

```text
{
  "socket_path": "/Users/alice/Library/Application Support/macos-auth/agent.sock",
  "hosts": [
    {
      "host_id": "linux-host-id",
      "public_key_file": "/Users/alice/Library/Application Support/macos-auth/hosts/linux-host-id.pub"
    }
  ],
  "agent_keychain_service": "com.macos-auth.agent",
  "agent_keychain_account": "default",
  "agent_key_id": "agent-key-1",
  "allowed_future_skew_ms": 30000,
  "require_confirmation": true,
  "rate_limit_window_seconds": 60,
  "rate_limit_max_requests": 5
}
```

Save it as `$HOME/Library/Application Support/macos-auth/agent-config.json` and make sure the `hosts` entry points at the copied Linux host public key.

### 4. Configure the Linux helper `[Linux]`

Run this on **Linux**. Start from the installed sample if you prefer:

```text
sudo cp /usr/share/macos-auth/examples/config.toml.sample /etc/macos-auth/config.toml
```

Create `/etc/macos-auth/config.toml` with:

```text
socket_path = "/run/user/1000/macos-auth-agent.sock"
host_key_file = "/etc/macos-auth/host_ed25519.key"
agent_pubkey_file = "/etc/macos-auth/agents.d/agent.pub"
key_id = "host-key-1"
host_id = "linux-host-id"
hostname = "linux.example.com"
service = "sudo"
timeout_ms = 15000
allowed_future_skew_ms = 30000
```

Important permissions:

```text
sudo chown -R root:root /etc/macos-auth
sudo chmod 0755 /etc/macos-auth /etc/macos-auth/agents.d
sudo chmod 0600 /etc/macos-auth/host_ed25519.key
sudo chmod 0644 /etc/macos-auth/config.toml /etc/macos-auth/agents.d/agent.pub
```

### 5. Configure SSH RemoteForward

This step is performed on **macOS**.

If you prefer, copy the installed sample to a temporary working file, edit `HostName`, `User`, the Linux-side UID, and the macOS-side socket path, then append it to `~/.ssh/config`:

```text
cp /opt/homebrew/share/macos-auth/examples/ssh-config.sample /tmp/macos-auth-ssh-config
$EDITOR /tmp/macos-auth-ssh-config
mkdir -p "$HOME/.ssh"
cat /tmp/macos-auth-ssh-config >> "$HOME/.ssh/config"
chmod 0600 "$HOME/.ssh/config"
```

Example SSH config on macOS:

```text
Host linux-with-macos-auth
    HostName linux.example.com
    User alice
    RemoteForward /run/user/1000/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
    StreamLocalBindUnlink yes
    ExitOnForwardFailure yes
```

Adjust `/run/user/1000` to the Linux user's UID and the macOS socket path to your agent config.

## How to use

### 1. Start the macOS agent `[macOS]`

If using the LaunchAgent helper, run this on **macOS**:

```text
/opt/homebrew/share/macos-auth/scripts/install-launchagent.sh \
  --agent-bin /opt/homebrew/bin/macos-auth-agent \
  --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

Check status:

```text
/opt/homebrew/share/macos-auth/scripts/status-launchagent.sh
```

### 2. Open SSH with RemoteForward `[macOS]`

Run SSH from **macOS** using the host entry that contains `RemoteForward`:

```text
ssh linux-with-macos-auth
```

Then, inside the resulting **Linux** session, confirm the forwarded socket exists:

```text
ls -l /run/user/$(id -u)/macos-auth-agent.sock
```

### 3. Test the helper directly `[Linux]`

Before using PAM, run this on **Linux**:

```text
/usr/bin/macos-auth-helper request \
  --config /etc/macos-auth/config.toml \
  --user "$USER" \
  --ruser "$USER" \
  --tty "$(tty | sed 's|^/dev/||')"
```

Expected exits:

| Exit | Meaning | Intended PAM behavior |
|---:|---|---|
| `0` | approved | success |
| `10` | agent unavailable | password fallback |
| `11` | user cancelled | password fallback |
| `12` | authentication failed | password fallback |
| `30` | signature/binding/freshness failure | hard fail |
| `31` | unsafe config | hard fail |
| `32` | protocol error | hard fail |

### 4. Test PAM without touching sudo `[Linux]`

Do **not** edit `/etc/pam.d/sudo` first. Run this on **Linux**.

Create a test service and use `pamtester`; see `docs/pam-testing.md` for distro-specific details.

Recommended control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper timeout_ms=25000 debug
```

### 5. Enable sudo only after pamtester succeeds `[Linux]`

Only after the test service works, edit `/etc/pam.d/sudo` on **Linux** and add the `pam_macos_auth.so` line near the top, keeping normal password authentication below it.

Always keep a separate root shell open while editing PAM.

## Components in this repository

| Component | Path | Purpose |
|---|---|---|
| Protocol crate | `crates/protocol` | Signed request/response types, canonical bytes, signature verification |
| Linux helper | `crates/helper` | Generates signed PAM requests, talks to agent socket, verifies responses |
| PAM shim | `pam/pam_macos_auth.c` | Extracts PAM context, invokes helper, maps helper exit codes to PAM results |
| Debian packaging | `packaging/linux/build-deb.sh`, `packaging/linux/deb/` | Native `.deb` package build |
| RPM packaging | `packaging/linux/build-rpm.sh`, `packaging/linux/rpm/` | Native `.rpm` package build |
| Linux setup helpers | `scripts/linux-*.sh` | Development config/install helpers for VM testing |

## Build prerequisites

Debian/Ubuntu builders:

```text
sudo apt-get update
sudo apt-get install -y build-essential cargo dpkg-dev libpam0g-dev make rustc
```

Fedora/RHEL-family builders:

```text
sudo dnf install -y cargo gcc make pam-devel rpm-build rust
```

Using a current Rust toolchain through `rustup` is also acceptable on local builders.

## Quality gate

Run before packaging or committing:

```text
make check
```

This runs:

- Rust formatting check
- Rust tests
- PAM C syntax check
- shell script syntax checks

Equivalent:

```text
scripts/check.sh
```

## Build Linux packages

### Debian/Ubuntu `.deb`

Run on a native Debian/Ubuntu builder:

```text
make package-deb
```

Equivalent:

```text
packaging/linux/build-deb.sh
```

The artifact is written under `target/package/deb/`.

### Fedora/RHEL `.rpm`

Run on a native Fedora/RHEL-family builder:

```text
make package-rpm
```

Equivalent:

```text
packaging/linux/build-rpm.sh
```

The artifact is written under `target/package/rpm/`.

If Rust is installed through `rustup` rather than distro RPM packages, `rpmbuild` dependency checks may not see it. In that case, install the distro `rust` / `cargo` packages or run with explicit local-builder options, for example:

```text
RPMBUILD_OPTS=--nodeps packaging/linux/build-rpm.sh
```

## Package contents

Linux packages install:

- `/usr/bin/macos-auth-helper`
- `pam_macos_auth.so` in the distro PAM module directory
- package documentation under `/usr/share/doc/macos-auth/`
- PAM examples under `/usr/share/macos-auth/examples/`
- sample Linux config: `/usr/share/macos-auth/examples/config.toml.sample`
- sample SSH config: `/usr/share/macos-auth/examples/ssh-config.sample`

Packages must not automatically modify `/etc/pam.d/sudo`.

## PAM testing

Do **not** edit `/etc/pam.d/sudo` first.

Use the test service and `pamtester` flow in:

- `docs/pam-testing.md`
- `pam/examples/macos-auth-test`

Recommended PAM control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper
```

This means:

- macOS approval succeeds immediately
- authenticator unavailable/cancel/failure falls back to password
- tampering/unsafe config/protocol errors hard fail

## Documentation index

| Document | Purpose |
|---|---|
| `docs/release-packaging.md` | Release packaging plan for Linux and macOS artifacts |
| `docs/release-runbook.md` | Reproducible release targets and release checklist |
| `docs/build-farm.md` | Local/native build farm policy and builder roles |
| `docs/linux-vm-test-plan.md` | Manual Parallels VM test plan for Ubuntu/Debian and Fedora/RHEL |
| `docs/pam-testing.md` | PAM testing guide |
| `docs/helper.md` | Linux helper usage |
| `pam/README.md` | PAM shim usage |
| `packaging/linux/README.md` | Linux package build notes |

## License

MIT. See `LICENSE`.
