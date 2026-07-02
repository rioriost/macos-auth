# Fallback and hard-fail policy

This document defines how `macos-auth` distinguishes safe fallback from hard failure.

The policy is central to the design:

- If the macOS authenticator path is unavailable, Linux password authentication may continue.
- If there is evidence of tampering, unsafe configuration, or protocol violation, authentication must fail closed.

## Summary

| Category | Meaning | Result |
|---|---|---|
| Approved | Verified macOS approval | PAM success |
| Unavailable | Authenticator/agent/transport unavailable | Password fallback |
| User-driven non-approval | Cancel or biometric/watch failure | Password fallback by default |
| Tampering / unsafe config | Invalid signatures, binding mismatch, unsafe files | Hard fail |
| Protocol error after connection | Malformed or invalid response path | Hard fail |

## Helper exit codes

`macos-auth-helper request` returns these exit codes for PAM use:

| exit code | meaning | intended PAM behavior |
|---:|---|---|
| 0 | approved | success |
| 10 | unavailable | password fallback |
| 11 | cancelled | password fallback by default |
| 12 | failed | password fallback |
| 20 | denied | hard fail by current PAM shim policy |
| 30 | tamper/signature/binding/freshness failure | hard fail |
| 31 | unsafe config | hard fail |
| 32 | protocol error after connection | hard fail |
| other | internal/unexpected | hard fail |

## PAM result mapping

`pam_macos_auth.so` maps helper exits as follows:

| helper exit | PAM result |
|---:|---|
| 0 | `PAM_SUCCESS` |
| 10 | `PAM_AUTHINFO_UNAVAIL` |
| 11 | `PAM_AUTHINFO_UNAVAIL` |
| 12 | `PAM_AUTHINFO_UNAVAIL` |
| 20 | `PAM_AUTH_ERR` |
| 30 | `PAM_AUTH_ERR` |
| 31 | `PAM_AUTH_ERR` |
| 32 | `PAM_AUTH_ERR` |
| other | `PAM_AUTH_ERR` |

Recommended PAM control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
```

With this syntax:

- `PAM_SUCCESS` stops auth successfully.
- `PAM_AUTHINFO_UNAVAIL` is ignored so later password auth runs.
- Any other result dies immediately.

## Fallback-allowed cases

Fallback is allowed when the macOS approval path cannot complete but there is no evidence that a forged approval was accepted.

### Agent unavailable

Examples:

- SSH `RemoteForward` is not connected.
- macOS agent is not running.
- Unix socket path does not exist.

Helper result: `10`.

Rationale: Linux password authentication still protects privilege escalation.

### Helper timeout

Examples:

- Agent hangs.
- Transport stalls.
- LocalAuthentication prompt is not completed within PAM shim timeout.

PAM shim result: helper timeout is mapped as exit `10` equivalent.

Rationale: This is equivalent to authenticator unavailability.

### LocalAuthentication unavailable

Examples:

- Apple Watch unavailable.
- Touch ID unavailable.
- Biometry not enrolled.
- Biometry locked out.

Agent decision: `unavailable`.
Helper result: `10`.

Rationale: The user can still authenticate with the Linux password.

### User cancel

Examples:

- User clicks `Use Linux Password` in confirmation UI.
- User cancels LocalAuthentication.

Agent decision: `cancelled`.
Helper result: `11`.

Rationale: The user intentionally chose not to use Apple Watch / Touch ID.

### Biometric/watch failure

Examples:

- LocalAuthentication returns authentication failure.

Agent decision: `failed`.
Helper result: `12`.

Rationale: Linux password fallback preserves availability without accepting the failed biometric path.

## Hard-fail cases

Hard-fail cases indicate tampering, unsafe state, or invalid protocol behavior. These must not silently fall back to password, because fallback could hide attacks or unsafe deployment.

### Invalid response signature

Helper result: `30`.

Rationale: The response cannot be trusted.

### Response binding mismatch

Examples:

- nonce mismatch
- request hash mismatch
- host id mismatch
- PAM service mismatch
- PAM user mismatch

Helper result: `30`.

Rationale: A valid response for another request must never authorize this request.

### Response freshness failure

Examples:

- response expired
- response created too far in the future

Helper result: `30`.

Rationale: Stale or time-shifted responses indicate replay or clock manipulation risk.

### Unsafe configuration

Examples:

- private key file is group/world readable
- config file is group/world writable
- agent public key file is group/world writable
- helper path is not safe

Helper result: `31`, or PAM shim returns `PAM_AUTH_ERR` directly.

Rationale: Unsafe config can invalidate trust in the authentication decision.

### Protocol error after connection

Examples:

- malformed response frame
- frame too large
- invalid JSON/protocol payload
- response cannot be decoded

Helper result: `32`.

Rationale: Once a peer is responding with malformed protocol data, treating it as mere unavailability can hide active interference.

## Bad PAM configurations

### Bad: `sufficient` without result discrimination

```text
auth sufficient pam_macos_auth.so conf=/etc/macos-auth/config.toml
```

This can make fallback and hard-fail behavior dependent on PAM defaults in a way that is harder to reason about.

### Bad: ignore all errors

```text
auth [success=done default=ignore] pam_macos_auth.so conf=/etc/macos-auth/config.toml
```

This would allow tamper/unsafe-config errors to fall through to password authentication, hiding attacks.

### Recommended

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
```

## Testing matrix

| Scenario | Expected helper exit | Expected PAM result | Expected user-visible behavior |
|---|---:|---|---|
| Agent approves | 0 | `PAM_SUCCESS` | sudo/pamtester succeeds |
| Agent socket missing | 10 | `PAM_AUTHINFO_UNAVAIL` | password prompt |
| User cancels confirmation | 11 | `PAM_AUTHINFO_UNAVAIL` | password prompt |
| LocalAuthentication unavailable | 10 | `PAM_AUTHINFO_UNAVAIL` | password prompt |
| LocalAuthentication failed | 12 | `PAM_AUTHINFO_UNAVAIL` | password prompt |
| Invalid agent signature | 30 | `PAM_AUTH_ERR` | hard fail |
| Response nonce mismatch | 30 | `PAM_AUTH_ERR` | hard fail |
| Replay cache duplicate | 30 | `PAM_AUTH_ERR` | hard fail |
| Unsafe private key file mode | 31 | `PAM_AUTH_ERR` | hard fail |
| Malformed response from socket | 32 | `PAM_AUTH_ERR` | hard fail |
| Helper timeout | 10 equivalent | `PAM_AUTHINFO_UNAVAIL` | password prompt |

## Future options

Potential future policy knobs:

- `on_cancel=fallback|fail`
- `on_denied=fallback|fail`
- `on_timeout=fallback|fail`

Defaults should remain availability-friendly for user-driven cancellation and authenticator unavailability, while keeping tampering and unsafe config as hard fail.
