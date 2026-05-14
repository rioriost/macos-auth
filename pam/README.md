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

## PAM configuration example

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
auth include common-auth
```

The helper must be an absolute path, a regular file, executable by owner, and not group/world writable. The development-only PAM option `unsafe_allow_helper_permissions` disables the group/world-writable helper check and should not be used in production.

The PAM shim also enforces a helper process timeout. Default: `timeout_ms=20000`. On timeout it terminates the helper and maps the result to `PAM_AUTHINFO_UNAVAIL`, which should fall back to password when using the recommended PAM control syntax.

Example with explicit timeout:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper timeout_ms=25000
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
