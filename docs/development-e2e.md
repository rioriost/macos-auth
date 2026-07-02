# Development end-to-end flow

This document describes the current development flow for testing the Linux helper, Swift macOS agent, SSH socket forwarding shape, and PAM shim pieces.

The project is still experimental. Do not install the PAM module on a system you cannot recover.

## 1. Build all components

From the repository root:

```text
cargo build
swift build --package-path agent
make -C pam check
```

To build the PAM bundle/module on the current platform:

```text
make -C pam
```

## 2. Quick setup scripts

You can use the helper scripts to generate the development config pieces.

First create or export the macOS agent public key:

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

Then create the Linux-side development files:

```text
cargo build
scripts/linux-dev-setup.sh \
  --host-id linux-host-id \
  --hostname linux.example.com \
  --agent-pubkey-file ./agent_ed25519.pub \
  --force
```

Then create the macOS-side agent config using the Linux host public key:

```text
scripts/macos-dev-setup.sh \
  --host-id linux-host-id \
  --host-pubkey-file ./macos-auth-linux-dev/host_ed25519.pub
```

The remaining sections describe the manual setup flow.

## 3. Generate Linux host key manually

On the Linux side, or locally for development:

```text
target/debug/macos-auth-helper gen-key \
  --private-key-file ./host_ed25519.key \
  --public-key-file ./host_ed25519.pub
```

The private key file must remain `0600`.

## 4. Generate macOS agent key manually

On macOS, prefer a development Keychain-backed key:

```text
agent/.build/debug/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default

agent/.build/debug/macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default > ./agent_ed25519.pub
```

For file-backed development only:

```text
agent/.build/debug/macos-auth-agent init-key \
  --private-key-file ./agent_ed25519.key \
  --public-key-file ./agent_ed25519.pub
```

The file-backed private key file must remain `0600`.

## 5. Create macOS agent config

Example development config:

```json
{
  "socket_path": "/tmp/macos-auth-agent.sock",
  "hosts": [
    {
      "host_id": "linux-host-id",
      "public_key_file": "./host_ed25519.pub"
    }
  ],
  "agent_keychain_service": "com.macos-auth.agent",
  "agent_keychain_account": "default",
  "agent_key_id": "agent-key-1",
  "allowed_future_skew_ms": 30000,
  "require_confirmation": true
}
```

Save it as `./agent-config.json` and ensure it is not group/world writable.

## 6. Run the macOS agent manually

For protocol-only testing:

```text
agent/.build/debug/macos-auth-agent fake-agent \
  --socket /tmp/macos-auth-agent.sock \
  --host-pubkey-hex <linux-host-public-key-hex> \
  --agent-key-file ./agent_ed25519.key
```

For LocalAuthentication testing:

```text
agent/.build/debug/macos-auth-agent serve --config ./agent-config.json
```

`serve` verifies the Linux request signature before showing any UI. By default it shows a confirmation alert with request context, then invokes LocalAuthentication.

## 7. Send a request with the Linux helper

```text
target/debug/macos-auth-helper request \
  --socket /tmp/macos-auth-agent.sock \
  --key-file ./host_ed25519.key \
  --agent-pubkey-file ./agent_ed25519.pub \
  --host-id linux-host-id \
  --hostname linux.example.com \
  --user alice \
  --ruser alice \
  --tty pts/3
```

Expected helper exits:

| exit | meaning |
|---:|---|
| 0 | approved |
| 10 | unavailable / fallback |
| 11 | cancelled / fallback |
| 12 | failed / fallback |
| 30 | tamper / hard fail |
| 31 | unsafe config / hard fail |
| 32 | protocol error / hard fail |

## 8. Test with SSH RemoteForward

Example SSH config:

```text
Host linux-with-macos-auth
    HostName linux.example.com
    User alice
    RemoteForward /run/user/1000/macos-auth-agent.sock /Users/YOUR_MAC_USER/Library/Application Support/macos-auth/agent.sock
    StreamLocalBindUnlink yes
    ExitOnForwardFailure yes
```

The Linux helper config should use the remote socket path:

```toml
socket_path = "/run/user/1000/macos-auth-agent.sock"
host_key_file = "/etc/macos-auth/host_ed25519.key"
agent_pubkey_file = "/etc/macos-auth/agents.d/alice.pub"
key_id = "host-key-1"
host_id = "linux-host-id"
hostname = "linux.example.com"
service = "sudo"
timeout_ms = 15000
allowed_future_skew_ms = 30000
```

## 9. PAM shim development configuration

Example PAM line:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper debug
```

Keep a separate root shell open before editing PAM configuration.

## 10. LaunchAgent installation on macOS

Build and copy the agent binary to a stable path, for example:

```text
mkdir -p "$HOME/.local/bin"
cp agent/.build/debug/macos-auth-agent "$HOME/.local/bin/macos-auth-agent"
```

Create a macOS agent config under:

```text
$HOME/Library/Application Support/macos-auth/agent-config.json
```

Install the LaunchAgent:

```text
scripts/install-launchagent.sh \
  --agent-bin "$HOME/.local/bin/macos-auth-agent" \
  --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

Logs go to:

```text
$HOME/Library/Logs/macos-auth/agent.stdout.log
$HOME/Library/Logs/macos-auth/agent.stderr.log
```

Check LaunchAgent status:

```text
scripts/status-launchagent.sh
```

Unload during development:

```text
scripts/uninstall-launchagent.sh --keep-plist
```

Unload and remove the plist:

```text
scripts/uninstall-launchagent.sh
```

## 11. Current limitations

- The agent key can be stored in Keychain as a generic password item, but it is not yet Secure Enclave non-exportable storage.
- The `serve` command uses LocalAuthentication but has minimal request-context UI.
- PAM integration has syntax/build coverage but still needs Linux VM end-to-end testing.
- Install scripts are development-oriented and not production hardening.
