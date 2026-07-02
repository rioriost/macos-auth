# SSH transport guide

`macos-auth` commonly uses SSH Unix-domain-socket forwarding to connect the Linux PAM helper to the macOS agent.

This document describes the transport assumptions and recommended SSH configuration.

## Core principle

SSH forwarding is transport only. It is not the trust boundary.

Security comes from:

- Linux host request signatures
- macOS agent response signatures
- pinned public keys
- nonce and request hash binding
- host allowlist on the macOS agent

If the SSH tunnel is tampered with, request/response signature verification should fail.

## Recommended shape

macOS runs the agent locally:

```text
/Users/YOUR_MAC_USER/Library/Application Support/macos-auth/agent.sock
```

SSH forwards that socket to Linux:

```text
/run/user/1000/macos-auth-agent.sock
```

Linux helper config points to the Linux-side socket:

```toml
socket_path = "/run/user/1000/macos-auth-agent.sock"
```

## SSH config example

```text
Host linux-with-macos-auth
    HostName linux.example.com
    User alice
    RemoteForward /run/user/1000/macos-auth-agent.sock /Users/YOUR_MAC_USER/Library/Application Support/macos-auth/agent.sock
    StreamLocalBindUnlink yes
    ExitOnForwardFailure yes
```

### `RemoteForward`

`RemoteForward` creates the socket on the Linux host and forwards it to the macOS agent socket.

This is preferred because the macOS agent is reachable only through the SSH session and does not need to listen on TCP.

### `StreamLocalBindUnlink yes`

This removes a stale Linux-side Unix socket before binding a new one.

Without it, reconnecting SSH may fail if the previous socket path remains.

### `ExitOnForwardFailure yes`

This makes SSH fail immediately if the socket forward cannot be established.

Without it, you might think macOS approval is available while the helper will actually fall back to password.

## Socket path selection

### Development

For local development, `/tmp/...` is acceptable.

### Single-user Linux host

A reasonable development path is:

```text
/run/user/UID/macos-auth-agent.sock
```

Example:

```text
/run/user/1000/macos-auth-agent.sock
```

### Multi-user Linux host

Be careful with shared paths.

Avoid:

```text
/tmp/macos-auth-agent.sock
```

unless it is only for local testing.

Prefer per-user runtime directories or root-managed directories with controlled ownership.

Potential future production path:

```text
/run/macos-auth/USER/agent.sock
```

This requires install-time directory management and SSH server configuration.

## Socket permissions are not enough

Unix socket permissions are useful for reducing accidental access, but `macos-auth` must not rely on them as the primary security boundary.

The macOS agent must still verify:

- request signature
- host id allowlist
- request freshness

The Linux helper must still verify:

- response signature
- response binding
- response freshness

## Difference from SSH agent forwarding

`macos-auth` should not use SSH agent forwarding for authentication.

SSH agent forwarding gives the remote host access to a generic signing interface. Even if private keys are not exportable, the remote side can request signatures.

`macos-auth` instead uses a dedicated protocol:

- macOS agent signs only structured `auth_response` messages
- responses are bound to verified `auth_request` messages
- arbitrary signing is not exposed
- request context is displayed before approval

## Known-bad configurations

### Bad: generic SSH agent forwarding

```text
ForwardAgent yes
```

Do not use this as the `macos-auth` transport.

### Bad: shared `/tmp` socket for multiple users

```text
RemoteForward /tmp/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
```

This can cause collisions and confusing access boundaries on multi-user systems.

### Bad: no `ExitOnForwardFailure`

```text
RemoteForward /run/user/1000/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
```

If forwarding fails, SSH may still connect. The helper will then fall back to password, which may hide deployment problems.

## Troubleshooting

### Helper always falls back to password

Check:

- Is the SSH session still open?
- Was `RemoteForward` established?
- Does the Linux-side socket exist?
- Is `socket_path` in `/etc/macos-auth/config.toml` correct?
- Is the macOS agent running?
- Does the macOS agent socket path match the SSH config?

### SSH says remote forward failed

Common causes:

- stale socket path without `StreamLocalBindUnlink yes`
- parent directory does not exist
- insufficient permissions to create socket
- SSH server disables stream local forwarding

Check server config for:

```text
AllowStreamLocalForwarding yes
```

### Agent receives no requests

Check:

- macOS agent log
- SSH verbose logs with `ssh -vvv`
- Linux helper direct invocation
- socket path mismatch between SSH config and helper config

### Invalid signature / hard fail

Check:

- Linux host public key in macOS agent allowlist
- macOS agent public key in Linux helper config
- host id matches exactly
- old keys were not regenerated without updating the other side

## Operational recommendations

- Use host-specific SSH config blocks.
- Avoid global `RemoteForward` rules.
- Avoid `ForwardAgent yes`.
- Use `ExitOnForwardFailure yes` during testing.
- Use per-host `host_id` values that are stable and unique.
- Rotate keys deliberately and update both sides atomically.
