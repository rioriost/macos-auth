# PAM testing guide

This document describes how to test `pam_macos_auth.so` without modifying `sudo` first.

Note for Parallels Desktop on Apple Silicon: Linux VMs are expected to be arm64/aarch64. On Debian/Ubuntu arm64, the PAM module directory is usually `/lib/aarch64-linux-gnu/security`, not `/lib/x86_64-linux-gnu/security`.

## Safety rules

- Do not edit `/etc/pam.d/sudo` until the separate `macos-auth-test` PAM service works.
- Keep a separate root shell open when editing any PAM configuration.
- Prefer testing in a VM or disposable Linux host.
- Have recovery access that does not depend on PAM auth you are editing.

## Build on Linux

```text
cargo build --release
make -C pam
```

For development builds:

```text
cargo build
make -C pam
```

## Prepare development config

Use the local development setup script first:

```text
scripts/linux-dev-setup.sh \
  --host-id linux-host-id \
  --hostname linux.example.com \
  --agent-pubkey-file ./agent_ed25519.pub \
  --force
```

This creates `./macos-auth-linux-dev` with:

- `host_ed25519.key`
- `host_ed25519.pub`
- `config.toml`
- `agents.d/agent.pub`

Make sure the macOS agent allowlist includes `host_ed25519.pub`.

## Install development artifacts

As root:

```text
sudo scripts/linux-install-dev.sh \
  --dev-dir ./macos-auth-linux-dev \
  --helper-bin target/debug/macos-auth-helper \
  --pam-module pam/pam_macos_auth.so \
  --install-pamtester-service \
  --force
```

This installs:

- `/usr/local/bin/macos-auth-helper`
- `pam_macos_auth.so` into the detected PAM module directory
- `/etc/macos-auth/config.toml`
- `/etc/macos-auth/host_ed25519.key`
- `/etc/macos-auth/agents.d/agent.pub`
- `/etc/pam.d/macos-auth-test`, if requested

It does **not** modify `/etc/pam.d/sudo`.

## Test helper directly

Before PAM, verify the helper path works:

```text
/usr/local/bin/macos-auth-helper request \
  --config /etc/macos-auth/config.toml \
  --user "$USER" \
  --ruser "$USER" \
  --tty "$(tty | sed 's|^/dev/||')"
```

Expected outcomes:

| exit | meaning |
|---:|---|
| 0 | approved |
| 10 | agent unavailable; fallback path |
| 11 | user cancelled; fallback path |
| 12 | auth failed; fallback path |
| 30 | tamper / signature / freshness failure |
| 31 | unsafe config |
| 32 | protocol error |

## Test PAM with pamtester

Install `pamtester` with your distribution package manager, then run:

```text
pamtester macos-auth-test "$USER" authenticate
```

Expected behavior:

- Apple Watch / Touch ID approved: `pamtester` succeeds.
- macOS agent unavailable: PAM falls through to the normal password module.
- Invalid signatures / unsafe config: PAM hard fails.

## Only after pamtester succeeds: sudo

Add this line near the top of `/etc/pam.d/sudo`, adapting paths if needed:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
```

Keep the existing password auth lines below it.

Test in a new terminal while keeping your root shell open:

```text
sudo -k
sudo true
```

## Remove development install

```text
sudo rm -f /usr/local/bin/macos-auth-helper
sudo rm -f /etc/pam.d/macos-auth-test
sudo rm -rf /etc/macos-auth
```

Also remove `pam_macos_auth.so` from your PAM module directory if desired.
