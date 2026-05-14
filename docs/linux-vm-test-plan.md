# Linux VM test plan

This document describes manual end-to-end testing in Linux VMs, with Parallels Desktop as the assumed VM platform.

Important Parallels Desktop constraint on Apple Silicon Macs: assume **arm64/aarch64 Linux guests only**. Do not use x86_64-specific package assumptions or PAM module paths without checking the VM.

The goal is to validate real PAM, `sudo`, SSH `RemoteForward`, fallback behavior, and hard-fail behavior on common Linux distributions.

## Scope

Test targets:

1. Ubuntu/Debian-family systems
2. Fedora/RHEL-family systems
3. build dependencies
4. install steps
5. `pamtester` flow
6. `sudo` flow
7. expected logs
8. rollback
9. test matrix

Arch Linux testing is deferred and is not part of the current VM plan.

## Safety rules

- Test in a disposable VM snapshot first.
- Take a VM snapshot before installing the PAM module.
- Do not edit `/etc/pam.d/sudo` until the `macos-auth-test` service passes with `pamtester`.
- Keep a root shell open while editing PAM.
- Ensure you have VM console access through Parallels Desktop.
- Do not test first on a machine you cannot recover.

## Parallels VM setup

Recommended baseline:

- 2 CPUs
- 2–4 GiB RAM
- bridged or shared networking
- OpenSSH server enabled
- a non-root test user with sudo privileges
- VM snapshot before PAM edits
- arm64/aarch64 distribution image on Apple Silicon

Record VM info:

```text
hostnamectl
uname -a
uname -m
id
sudo -l
```

## Common macOS-side setup

On macOS, build and prepare the agent:

```text
make check

agent/.build/debug/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default \
  --overwrite

agent/.build/debug/macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default > ./agent_ed25519.pub
```

The Linux VM will need `agent_ed25519.pub`.

## Distribution build dependencies

### Ubuntu / Debian

```text
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  curl \
  git \
  libpam0g-dev \
  make \
  openssh-server \
  pamtester \
  pkg-config
```

Install Rust if needed:

```text
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
```

PAM module directory on arm64 Debian/Ubuntu is usually:

```text
/lib/aarch64-linux-gnu/security
```

On x86_64 Linux it is often `/lib/x86_64-linux-gnu/security`, but Parallels Desktop on Apple Silicon should use arm64/aarch64 guests.

PAM stack names:

- `common-auth`
- `common-account`

### Fedora / RHEL-family

Fedora:

```text
sudo dnf install -y \
  @development-tools \
  git \
  make \
  openssh-server \
  pam-devel \
  pamtester \
  pkgconf-pkg-config \
  rust cargo
```

RHEL-like systems may require EPEL for `pamtester`.

PAM module directory is commonly:

```text
/lib64/security
```

Confirm on the VM with:

```text
find /lib /lib64 /usr/lib -name pam_unix.so 2>/dev/null
```

PAM stack names:

- `system-auth`

SELinux note:

- Fedora/RHEL may need SELinux context adjustments for non-standard paths.
- Prefer installing helper/config into conventional root-owned paths from `scripts/linux-install-dev.sh`.

## Linux VM repository setup

Clone or copy the repository into the VM:

```text
git clone <repo-url> macos-auth
cd macos-auth
```

Build:

```text
cargo build
make -C pam
```

If building `pam_macos_auth.so` fails, verify PAM headers are installed.

## Linux development config generation

Copy `agent_ed25519.pub` from macOS to the VM.

For example, from macOS:

```text
scp ./agent_ed25519.pub alice@linux.example.com:/home/alice/agent_ed25519.pub
```

In the VM:

```text
scripts/linux-dev-setup.sh \
  --host-id linux-vm-ubuntu \
  --hostname "$(hostname -f 2>/dev/null || hostname)" \
  --agent-pubkey-file "$HOME/agent_ed25519.pub" \
  --socket-path "/run/user/$(id -u)/macos-auth-agent.sock" \
  --force
```

This produces:

```text
./macos-auth-linux-dev/host_ed25519.pub
./macos-auth-linux-dev/host_ed25519.key
./macos-auth-linux-dev/config.toml
```

Copy the Linux host public key back to macOS:

```text
scp alice@linux.example.com:/home/alice/macos-auth/macos-auth-linux-dev/host_ed25519.pub ./host_ed25519.pub
```

## macOS agent config for the VM

On macOS:

```text
scripts/macos-dev-setup.sh \
  --host-id linux-vm-ubuntu \
  --host-pubkey-file ./host_ed25519.pub \
  --overwrite-keychain
```

Run the agent manually first:

```text
"$HOME/.local/bin/macos-auth-agent" serve \
  --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

## SSH RemoteForward test

From macOS, SSH into the VM with a remote Unix socket forward:

```text
ssh \
  -o StreamLocalBindUnlink=yes \
  -o ExitOnForwardFailure=yes \
  -R "/run/user/1000/macos-auth-agent.sock:$HOME/Library/Application Support/macos-auth/agent.sock" \
  alice@linux.example.com
```

Adjust `/run/user/1000` to the VM user's UID.

Inside the VM, verify the socket exists:

```text
ls -l "/run/user/$(id -u)/macos-auth-agent.sock"
```

## Direct helper test

Inside the VM:

```text
target/debug/macos-auth-helper request \
  --config ./macos-auth-linux-dev/config.toml \
  --user "$USER" \
  --ruser "$USER" \
  --tty "$(tty | sed 's|^/dev/||')"
```

Expected:

- macOS confirmation alert appears
- LocalAuthentication appears
- approval returns exit `0`
- cancellation returns exit `11`
- missing socket returns exit `10`

## Install into system paths

Inside the VM:

```text
sudo scripts/linux-install-dev.sh \
  --dev-dir ./macos-auth-linux-dev \
  --helper-bin target/debug/macos-auth-helper \
  --pam-module pam/pam_macos_auth.so \
  --install-pamtester-service \
  --force
```

If the PAM module directory is not auto-detected, pass `--pam-dir`.

Examples:

```text
sudo scripts/linux-install-dev.sh --dev-dir ./macos-auth-linux-dev --pam-dir /lib/aarch64-linux-gnu/security --install-pamtester-service --force
sudo scripts/linux-install-dev.sh --dev-dir ./macos-auth-linux-dev --pam-dir /lib64/security --install-pamtester-service --force
sudo scripts/linux-install-dev.sh --dev-dir ./macos-auth-linux-dev --pam-dir /usr/lib/security --install-pamtester-service --force
```

## pamtester flow

### Ubuntu / Debian

The installed `/etc/pam.d/macos-auth-test` uses:

```text
auth include common-auth
account include common-account
```

Run:

```text
pamtester macos-auth-test "$USER" authenticate
```

Expected cases:

| Case | Expected |
|---|---|
| Approve on macOS | success |
| Cancel confirmation | password fallback |
| Stop macOS agent | password fallback |
| Wrong agent public key | hard fail |
| Unsafe host key mode | hard fail |

### Fedora / RHEL-family

If `common-auth` does not exist, create a Fedora-specific test service:

```text
sudo tee /etc/pam.d/macos-auth-test >/dev/null <<'EOF'
#%PAM-1.0
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper timeout_ms=25000 debug
auth include system-auth
account include system-auth
EOF
```

Then:

```text
pamtester macos-auth-test "$USER" authenticate
```

## sudo flow

Only after `pamtester` succeeds:

1. Open a root shell and keep it open.
2. Backup sudo PAM config.
3. Add the `pam_macos_auth.so` line near the top.
4. Test in a second terminal.

Example Ubuntu/Debian:

```text
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak.macos-auth
sudoedit /etc/pam.d/sudo
```

Add near the top:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper timeout_ms=25000
```

Test:

```text
sudo -k
sudo true
```

Expected:

- approval succeeds without Linux password
- cancel falls back to Linux password
- agent unavailable falls back to Linux password
- invalid signature hard fails

## Expected logs

### macOS agent

Manual agent logs appear on stderr:

```text
macos-auth-agent request request_id=... host_id=... host=... service=sudo user=... ruser=... tty=...
```

LaunchAgent logs:

```text
$HOME/Library/Logs/macos-auth/agent.stdout.log
$HOME/Library/Logs/macos-auth/agent.stderr.log
```

### Linux helper / PAM

Helper direct invocation prints errors to stderr.

PAM shim logs through syslog / authpriv. Check distro-specific logs:

Ubuntu/Debian:

```text
sudo journalctl -t sudo
sudo tail -f /var/log/auth.log
```

Fedora/RHEL:

```text
sudo journalctl -f
sudo ausearch -m USER_AUTH,USER_ACCT 2>/dev/null || true
```

## Rollback

### Revert sudo PAM config

```text
sudo cp /etc/pam.d/sudo.bak.macos-auth /etc/pam.d/sudo
```

or remove the `pam_macos_auth.so` line using the root shell you kept open.

### Remove test service

```text
sudo rm -f /etc/pam.d/macos-auth-test
```

### Remove installed artifacts

```text
sudo rm -f /usr/local/bin/macos-auth-helper
sudo rm -rf /etc/macos-auth
```

Remove the PAM module from the module directory if desired:

```text
sudo rm -f /lib/x86_64-linux-gnu/security/pam_macos_auth.so
sudo rm -f /lib64/security/pam_macos_auth.so
sudo rm -f /usr/lib/security/pam_macos_auth.so
```

### Stop macOS agent

```text
scripts/uninstall-launchagent.sh --keep-plist
```

or if running manually, stop the process with Ctrl-C.

## Test matrix

Run this matrix per distribution.

| ID | Test | Expected |
|---|---|---|
| H1 | helper direct approve | exit `0` |
| H2 | helper direct cancel | exit `11` |
| H3 | helper with missing socket | exit `10` |
| H4 | helper with wrong agent public key | exit `30` |
| H5 | helper with host key mode `0644` | exit `31` |
| P1 | pamtester approve | success |
| P2 | pamtester cancel | password fallback |
| P3 | pamtester agent unavailable | password fallback |
| P4 | pamtester wrong key | hard fail |
| S1 | sudo approve | succeeds without Linux password |
| S2 | sudo cancel | falls back to Linux password |
| S3 | sudo agent unavailable | falls back to Linux password |
| S4 | sudo wrong key | hard fail |
| T1 | SSH RemoteForward missing | helper fallback |
| T2 | SSH RemoteForward established | helper reaches agent |

## Distribution notes to record

For each VM, record:

```text
Distribution:
Version:
Kernel:
Architecture:
PAM module directory:
PAM include style:
SELinux/AppArmor status:
OpenSSH version:
Result summary:
Issues found:
```

## Success criteria

A distribution is considered manually validated when:

- direct helper flow works
- `pamtester` flow works
- `sudo` flow works
- fallback cases prompt for password
- hard-fail cases do not fall through
- rollback is verified
