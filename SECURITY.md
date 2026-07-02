# Security Policy

`macos-auth` is experimental authentication software. It is not production-ready.

## Supported versions

No released version is currently supported for production use. Until a tagged release exists, treat `main` as development-only.

## Reporting vulnerabilities

Do not report suspected vulnerabilities in public issues if the repository is public.

Preferred reporting channels, in order:

1. Use GitHub private vulnerability reporting if enabled for the repository.
2. Contact the maintainer privately.
3. If no private channel is available, open a public issue with minimal non-exploit details and ask for a private contact path.

Please include:

- affected commit or version
- component: Rust helper, Swift agent, PAM shim, scripts, docs
- threat model assumptions
- reproduction steps if safe to share
- whether the issue enables privilege escalation, authentication bypass, key disclosure, replay, or prompt spoofing

## Current security status

The project currently has several important hardening gaps:

- The macOS agent can store signing keys in Keychain generic-password items, but this is not yet non-exportable Secure Enclave storage. See `docs/keychain-and-secure-enclave.md`.
- The Swift agent uses a development JSON config format.
- The PAM module has syntax/build checks but still needs Linux VM end-to-end testing.
- Installer scripts are development-oriented.
- The confirmation UI is an initial `NSAlert` implementation.
- No external security review has been performed.

## Security goals

The intended security properties are:

- The SSH tunnel is transport only, not a trust boundary.
- Linux requests are signed by a root-owned host key.
- macOS responses are signed by a pinned agent key.
- Responses bind to request hash, nonce, host id, PAM service, and PAM user.
- Authenticator unavailable/cancel/failure falls back to Linux password authentication.
- Tampering, invalid signatures, unsafe config, and protocol errors fail closed.
- The macOS agent must not act as a generic signing oracle.
- Unverified requests must not trigger Apple Watch / Touch ID prompts.

## Out of scope

`macos-auth` cannot protect against:

- a fully malicious Linux root on the target host
- a fully compromised macOS user session
- malicious modification of installed binaries/configs by a privileged local attacker
- user approval of malicious prompts after ignoring displayed context

## Production readiness bar

Before any production recommendation, the project should have:

- Linux VM end-to-end PAM tests
- fuzzing for protocol parsers / frame handling
- Secure Enclave or equivalent non-exportable agent signing key support, if feasible
- stronger installer safety checks and rollback
- documented recovery procedures
- threat model review
- external security review
