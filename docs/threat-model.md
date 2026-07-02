# Threat model

This document describes the current threat model for `macos-auth`.

## Assets

The project is designed to protect:

- Linux privilege escalation through `sudo` or other PAM services
- macOS agent signing key material
- Linux host signing key material
- integrity of a single authentication transaction
- user intent when approving a remote authentication request

## Security goals

`macos-auth` aims to provide these properties:

1. A Linux PAM authentication request is approved only after a verified macOS agent response.
2. The macOS agent only prompts after verifying the Linux host signature and host allowlist.
3. A response is bound to one request through request hash, nonce, host id, service, and user.
4. Authenticator unavailable/cancel/failure falls back to normal Linux password authentication.
5. Tampering, invalid signatures, unsafe config, and protocol errors fail closed.
6. The SSH tunnel is transport only, not a trust boundary.
7. The macOS agent must not act as a generic signing oracle.

## Non-goals

`macos-auth` does not attempt to protect against:

- a malicious Linux root on the target host
- a fully compromised macOS user session
- a malicious user approving a prompt without reading context
- malware with the same privileges as the macOS agent process
- physical compromise of an unlocked Mac
- compromise of both Linux host private key and macOS agent private key

## Trust assumptions

### Linux host

The Linux host root is trusted to protect:

- `/etc/macos-auth/host_ed25519.key`
- `/etc/macos-auth/config.toml`
- `pam_macos_auth.so`
- `/usr/local/bin/macos-auth-helper`
- PAM configuration

If Linux root is malicious, it can bypass or alter PAM behavior. The protocol still avoids exposing a generic macOS signing oracle, but it cannot make a malicious root trustworthy.

### macOS host

The macOS user session is trusted to run the intended agent binary and protect its Keychain access. The current Keychain generic-password storage is not non-exportable; this is a known limitation.

### Transport

SSH forwarding / Unix sockets are not trusted for authenticity or integrity. All request and response authenticity comes from pinned public keys and signatures. Operational guidance is documented in `docs/ssh-transport.md`.

## Attack classes

### Transport tampering

Attack: Modify request/response bytes in transit.

Mitigation:

- Linux request signature verified by macOS agent.
- macOS response signature verified by Linux helper.
- Response includes request hash and nonce.

Expected behavior:

- Invalid request is rejected before UI.
- Invalid response maps to hard fail.

### Response substitution

Attack: Use a valid response for a different request.

Mitigation:

- Response body includes request hash, nonce, host id, service, and user.
- Linux helper checks response binding against the original request body.

Expected behavior:

- Substituted response maps to hard fail.

### Replay

Attack: Replay an old valid response.

Current mitigation:

- Each helper invocation generates a new nonce.
- Response is bound to request hash and nonce.
- Response has an expiry timestamp.
- The helper verifies freshness.

Current optional hardening:

- The Linux helper supports `replay_cache_dir`.
- When configured, it records a marker keyed by the SHA-256 hash of the response signature.
- Markers are created with `O_CREAT | O_EXCL`; an existing marker is treated as replay and hard-fails.
- Marker files include response expiry and are cleaned up best-effort.

Residual risk:

- The replay cache is optional and must be backed by a root-owned directory with restrictive permissions.
- If no replay cache is configured, replay protection relies on fresh nonces, response binding, and expiry.

### Fake Linux host request

Attack: A process sends a fake request to the macOS agent socket.

Mitigation:

- Agent verifies host signature before UI.
- Agent selects the verification key by `linux_host_id` allowlist.

Expected behavior:

- No confirmation UI or LocalAuthentication prompt for invalid or unlisted hosts.

### Prompt bombing

Attack: A compromised Linux account repeatedly triggers prompts.

Current mitigation:

- Agent only prompts after host signature verification.
- Confirmation UI displays host, user, tty, service, and request id.

Residual risk:

- A legitimate but compromised Linux account can still cause repeated valid prompts.

Planned hardening:

- Per-host rate limiting.
- Prompt coalescing.
- Temporary block after repeated cancels.

### Generic signing oracle

Attack: Abuse the macOS agent to sign arbitrary data.

Mitigation:

- Agent only accepts structured `auth_request` frames.
- Agent only returns structured `auth_response` frames.
- Response body is constructed by the agent and bound to the verified request.

Expected behavior:

- There is no arbitrary signing API.

### Unsafe fallback

Attack: Force fallback in a way that bypasses authentication.

Mitigation:

- Fallback only means normal Linux password authentication continues.
- Tampering and unsafe config map to hard fail, not fallback.

Fallback cases:

- macOS agent unavailable
- SSH tunnel unavailable
- helper timeout
- LocalAuthentication unavailable
- user cancel
- biometric/watch auth failure

Hard-fail cases:

- invalid response signature
- nonce/request hash mismatch
- unknown agent key
- malformed response
- unsafe config permissions
- protocol errors after connection

## Key management risks

### Linux host key

The Linux host key is currently file-backed and root-owned. It must be mode `0600` and protected by root.

### macOS agent key

The macOS agent key can currently be:

- inline hex, development only
- file-backed, development only
- Keychain generic-password backed, preferred for development

Known limitation:

- Generic-password Keychain storage is not non-exportable. The agent can read raw private key bytes.

Planned hardening:

- Investigate Secure Enclave backed P-256 signing.
- Extend protocol to support pinned algorithm identifiers if Ed25519 is not possible with Secure Enclave.

## PAM-specific risks

PAM is sensitive to configuration mistakes.

Mitigations:

- Separate `macos-auth-test` service for `pamtester`.
- Recommended control syntax separates fallback and hard fail.
- PAM shim enforces helper timeout.
- PAM shim uses `execve`, not shell.
- PAM shim uses sanitized environment.

Remaining work:

- Linux VM integration tests.
- Distro-specific PAM guidance.
- Installer rollback.

## Fallback policy

The exact fallback vs hard-fail behavior is documented in `docs/fallback-policy.md`.

## Current status

The project currently satisfies the core protocol binding and fallback/hard-fail design in development form, but it is not production-ready.
