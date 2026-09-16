# Security hardening checklist

This document tracks what must be true before `macos-auth` should be considered beyond experimental.

## Current recommendation

Do not use `macos-auth` as a production authentication mechanism yet. Use only in a VM, lab host, or disposable environment until the checklist is substantially complete.

## Implemented controls

### Protocol

- [x] Linux request signing with Ed25519 / Curve25519 signing keys
- [x] macOS response signing
- [x] nonce binding
- [x] request hash binding in response
- [x] host id / PAM service / PAM user binding
- [x] response freshness check
- [x] domain-separated canonical bytes for signatures
- [x] no direct signing of JSON bytes

### Linux helper

- [x] private key file permission check
- [x] public key file permission check
- [x] config file permission check
- [x] explicit PAM production root ownership, ancestor and no-symlink validation
- [x] validated file descriptors for trusted reads and replay-cache updates
- [x] absolute connect/write/read deadline; request expiry rechecked before approval
- [x] unavailable agent maps to fallback exit code
- [x] tamper / invalid response maps to hard-fail exit code
- [x] integration tests for success / unavailable / unsafe config

### PAM shim

- [x] no shell invocation; uses Linux `fexecve` on a validated descriptor
- [x] sanitized environment
- [x] helper executable permission check
- [x] root-owned helper and ancestors; no permission-bypass PAM option
- [x] close all inherited descriptors, including those above 1023
- [x] helper process timeout with fallback mapping
- [x] fallback vs hard-fail exit code mapping
- [x] syntax check through the local quality gate
- [x] noninteractive C unit harness (`make -C pam test`); no live PAM changes
- [x] separate `macos-auth-test` PAM service example for `pamtester`

### macOS agent

- [x] verifies request signature before UI
- [x] host allowlist by `linux_host_id`
- [x] request freshness check
- [x] confirmation UI before LocalAuthentication
- [x] LocalAuthentication integration
- [x] signed response decisions for approved/cancelled/unavailable/failed
- [x] Keychain generic-password storage for development agent key
- [x] config and key file permission checks

### Tooling

- [x] local `make check`
- [x] development setup scripts
- [x] PAM testing guide

## Required before beta

### Protocol / parsing

- [x] Formally specify current JSON frame transport limits. Replacement with stricter binary encoding remains a future option.
- [ ] Add parser fuzzing for frame handling and JSON/protocol decoding. Initial cargo-fuzz skeleton and negative frame decoder tests are implemented, but sustained fuzzing is still pending.
- [x] Add cross-language test vectors checked by both Rust and Swift, including all 25 response decision/method combinations.
- [x] Add replay cache or explicit replay handling strategy.
- [x] Add clock skew tests.

### Linux helper

- [ ] Add structured config validation with clearer diagnostics.
- [ ] Add syslog support for PAM use.
- [ ] Avoid leaking sensitive command args in logs.
- [x] Install `/usr/bin/macos-auth-helper` and relocate config/key/replay paths.
- [ ] Add Linux VM tests.

### PAM shim

- [ ] Test with real Linux PAM using `pamtester` in manual VM flow or VM automation.
- [ ] Confirm behavior across Debian/Ubuntu and Fedora/RHEL-family PAM stacks.
- [ ] Add sudo-specific integration documentation per distro.
- [x] Add timeout protection around helper process execution.
- [ ] Consider dropping privileges where possible, without breaking root-owned key access.

### macOS agent

- [ ] Replace generic-password Keychain storage with non-exportable Secure Enclave storage if feasible.
- [ ] If Secure Enclave requires P-256, extend protocol to support P-256 signatures with pinned algorithms.
- [ ] Add a proper app/agent UI instead of only `NSAlert`.
- [x] Add rate limiting / prompt bombing protection.
- [x] Add host management commands: list/add/remove hosts.
- [x] Add Keychain access control review.
- [x] Add LaunchAgent install/uninstall commands with validation.

### Installer / operations

- [ ] Add dry-run mode to installers.
- [ ] Add backups and rollback instructions for PAM changes.
- [ ] Add explicit recovery instructions for locked-out sudo.
- [ ] Add package signing / checksums for release artifacts.
- [ ] Add uninstall scripts.

### Documentation

- [x] Complete initial threat model document.
- [x] Document exact fallback vs hard-fail semantics.
- [x] Document SSH RemoteForward security assumptions.
- [x] Document known-bad configurations.
- [x] Document limitations of Apple Watch / Touch ID policies per macOS version.

## Known risks

### Generic-password Keychain storage

The current Keychain support stores raw Curve25519 private key material in a generic-password item. This avoids inline config or plain files, but the agent process can still read/export the key. This is not equivalent to Secure Enclave non-exportable signing.

### LocalAuthentication policy behavior

The agent uses Apple Watch / biometric companion policies where available. macOS policy behavior and password fallback behavior must be tested across supported macOS versions.

### PAM misconfiguration

PAM misconfiguration can lock users out or break `sudo`. Always test with `pamtester` and keep a root shell open before changing `sudo`.

### Remote root assumptions

If the Linux host root is malicious, it can alter PAM config, helper binaries, and host private keys. The project aims to avoid giving such a host a generic macOS signing oracle, but it cannot make a compromised root trustworthy.
