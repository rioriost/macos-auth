# macOS agent

This directory contains the initial Swift package for the macOS user-session agent.

Current implementation:

1. Provides `macos-auth-agent fake-agent` for protocol testing.
2. Provides `macos-auth-agent serve` for an initial LocalAuthentication-backed flow.
3. Listens on a local Unix domain socket.
4. Reads the same length-prefixed JSON frame format used by `macos-auth-helper`.
5. Reconstructs canonical request bytes and verifies Linux host Ed25519 signatures.
6. Builds a response bound to the request hash / nonce / host / service / user.
7. Signs the response with a CryptoKit `Curve25519.Signing.PrivateKey`.
8. In `serve`, uses `LocalAuthentication.framework` and returns `approved`, `cancelled`, `unavailable`, or `failed`.

The current `serve` command is still a development implementation. It uses a JSON config file and a development agent private key source. Keychain / Secure Enclave storage and host allowlist UX still need to be hardened.

## Build

```text
swift build --package-path agent
swift test --package-path agent
```

Tests use disposable project-local fixtures, mock authentication, and fixed
development keys; they do not invoke biometric UI or access Keychain.

## Fake-agent example

```text
agent/.build/debug/macos-auth-agent fake-agent \
  --socket /tmp/macos-auth-agent.sock \
  --host-pubkey-hex <linux-host-public-key-hex> \
  --agent-key-file ./agent_ed25519.key \
  --once
```

Then in another terminal:

```text
target/debug/macos-auth-helper request \
  --socket /tmp/macos-auth-agent.sock \
  --key-file ./host_ed25519.key \
  --agent-pubkey-file ./agent_ed25519.pub \
  --host-id host-abc \
  --hostname linux.example.com \
  --user alice
```

## Key setup

Generate a development agent keypair:

```text
agent/.build/debug/macos-auth-agent init-key \
  --private-key-file ./agent_ed25519.key \
  --public-key-file ./agent_ed25519.pub
```

The private key file is created with mode `0600`; the public key file is created with mode `0644`.

Print the public key for an existing private key:

```text
agent/.build/debug/macos-auth-agent print-public-key --agent-key-file ./agent_ed25519.key
```

You can also store a development key in the user's Keychain generic-password store:

```text
agent/.build/debug/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default
```

Print the public key for the Keychain-backed key:

```text
agent/.build/debug/macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default
```

The current Keychain implementation stores the same raw Curve25519 private key material as a generic password item with `ThisDeviceOnly` accessibility. This is better than inline config material, but it is still exportable by this agent process and is not yet Secure Enclave non-exportable storage.

## Serve example

Create a development JSON config:

```json
{
  "socket_path": "/tmp/macos-auth-agent.sock",
  "hosts": [
    {
      "host_id": "host-abc",
      "public_key_hex": "<linux-host-public-key-hex>"
    }
  ],
  "agent_keychain_service": "com.macos-auth.agent",
  "agent_keychain_account": "default",
  "agent_key_id": "agent-key-1",
  "allowed_future_skew_ms": 30000,
  "require_confirmation": true
}
```

For backward-compatible development tests, `host_public_key_hex` / `host_public_key_file` can still be used as a single wildcard host key. Prefer the `hosts` allowlist for real testing.

Then run:

```text
agent/.build/debug/macos-auth-agent serve --config ./agent-config.json
```

`serve` verifies the request signature before showing any UI. The optional
confirmation alert adds host/user/tty/request context before LocalAuthentication;
`require_confirmation` defaults to `false`, and the example above opts in. If
LocalAuthentication succeeds within the request lifetime, the agent signs an
`approved` response. If it is cancelled or unavailable, it signs a fallback-safe
response decision while the request is still live.

The server admits at most eight active connections, with a two-second initial
frame-read budget and fifteen-second total connection cap. Authentication UI is
serialized on the main thread, and queued requests retain their original signed
expiry. Expiry or disconnect cancels pending authentication and cannot result in
a late approval. See [LocalAuthentication notes](../docs/macos-local-authentication.md).

## Socket and file safety

The socket is created with mode `0600`. Its parent must be owned by the effective
user or root and not group/world writable; a root-owned sticky directory is also
accepted. Parent-directory symlinks are resolved (including macOS's `/tmp`
alias), but a symlink at the socket pathname is rejected. Existing regular files,
foreign-owned sockets, and live listeners are never unlinked. Only an owned
socket that refuses a connection and retains its device/inode identity is treated
as stale. Shutdown removes only the socket identity created by this listener.
Prefer a private per-user socket directory.

Config and key reads reject final-path symlinks, non-regular files, and owners
other than the effective user or root. Public/config files must not be
group/world writable; private key files and configs containing `agent_key_hex`
must not grant any group/world permissions. Use mode `0600` for inline-secret
configs (Keychain is preferable).

Host-list updates use an exclusively created, initially `0600` replacement file
in the config directory and atomically rename it after checked writes and sync.
They preserve the original owner and permissions, narrowing inline-secret
configs to owner-only permissions; an existing `0600` config is not widened to
`0644`. The config directory itself must not be group/world writable.

## Host allowlist management

List configured hosts:

```text
agent/.build/debug/macos-auth-agent hosts list --config ./agent-config.json
```

Add a host:

```text
agent/.build/debug/macos-auth-agent hosts add \
  --config ./agent-config.json \
  --host-id linux-host-id \
  --public-key-file ./host_ed25519.pub
```

Remove a host:

```text
agent/.build/debug/macos-auth-agent hosts remove \
  --config ./agent-config.json \
  --host-id linux-host-id
```

## Development setup script

After you have a Linux host public key, you can generate the macOS-side development config and optionally install the LaunchAgent:

```text
scripts/macos-dev-setup.sh \
  --host-id linux-host-id \
  --host-pubkey-file ./macos-auth-linux-dev/host_ed25519.pub \
  --install-launchagent
```

Check status:

```text
scripts/status-launchagent.sh
```

Uninstall:

```text
scripts/uninstall-launchagent.sh
```

## Next step

The next agent milestones are:

1. replace generic-password Keychain storage with non-exportable Secure Enclave storage where possible
2. improve confirmation UI beyond the current NSAlert-based implementation
3. LaunchAgent plist hardening
4. migration away from inline private key material

The agent must not expose a generic signing API. It should only sign structured `auth_response` messages for verified `auth_request` messages.
