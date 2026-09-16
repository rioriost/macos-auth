# PAM module

This directory contains the initial Linux PAM integration shim.

The MVP shape is a minimal C PAM module that:

1. Extracts PAM context such as service, user, ruser, rhost, and tty.
2. Executes the root-owned `macos-auth-helper` with a sanitized environment.
3. Maps helper exit codes to PAM return codes.

The security-sensitive protocol parsing, request signing, socket IO, and response verification live in Rust so they can be tested and fuzzed independently.

## Build

```text
make -C pam
```

For a syntax-only check:

```text
make -C pam check
```

For noninteractive unit tests without root or live PAM configuration:

```text
make -C pam test
```

Linux tests exercise real fd execution. macOS tests use a test-only native
execution adapter; the actual module fails closed there because macOS does not
provide `fexecve`. Deploy this module only on Linux.

## PAM configuration example

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper
auth include common-auth
```

The helper must be an absolute path, a root-owned regular file, executable by
owner, and not group/world writable. All ancestors must be root-owned,
non-writable by others, and not symlinks. The validated descriptor is executed
with Linux `fexecve`; arbitrary inherited descriptors are closed. The former
`unsafe_allow_helper_permissions` option no longer bypasses validation.
PAM always passes `--require-root-owned` to enforce the same trust policy on
config, keys, and replay cache. User-owned development setups are tested by
invoking the helper directly, never by weakening PAM.

The PAM shim also enforces a helper process timeout. Default: `timeout_ms=20000`. On timeout it terminates the helper and maps the result to `PAM_AUTHINFO_UNAVAIL`, which should fall back to password when using the recommended PAM control syntax.

Example with explicit timeout:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper timeout_ms=25000
```

## Helper exit code mapping

| helper exit | PAM result | behavior |
|---:|---|---|
| 0 | `PAM_SUCCESS` | authentication accepted |
| 10 | `PAM_AUTHINFO_UNAVAIL` | password fallback |
| 11 | `PAM_AUTHINFO_UNAVAIL` | password fallback by default |
| 12 | `PAM_AUTHINFO_UNAVAIL` | password fallback |
| 20 | `PAM_AUTH_ERR` | hard fail |
| 30 | `PAM_AUTH_ERR` | hard fail |
| 31 | `PAM_AUTH_ERR` | hard fail |
| 32 | `PAM_AUTH_ERR` | hard fail |
| other | `PAM_AUTH_ERR` | hard fail |
