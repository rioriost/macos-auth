# macOS LocalAuthentication notes

`macos-auth-agent serve` uses Apple's `LocalAuthentication.framework` to ask the local macOS user to approve a verified Linux PAM request.

This document records current assumptions, limitations, and testing requirements.

## Current implementation

The agent selects the policy by macOS version:

| macOS version | Policy |
|---|---|
| macOS 15+ | `deviceOwnerAuthenticationWithBiometricsOrCompanion` |
| macOS 10.15–14 | `deviceOwnerAuthenticationWithBiometricsOrWatch` |

The agent flow is:

1. verify Linux host allowlist
2. verify request signature
3. verify request freshness
4. show confirmation UI, unless `require_confirmation=false`
5. call `LAContext.canEvaluatePolicy`
6. call `LAContext.evaluatePolicy`
7. map the result to a signed response decision

## Result mapping

| LocalAuthentication result | Agent decision | Linux behavior |
|---|---|---|
| success | `approved` | PAM success |
| user/system/app cancel | `cancelled` | password fallback |
| biometry/watch unavailable | `unavailable` | password fallback |
| biometry not enrolled | `unavailable` | password fallback |
| biometry lockout | `unavailable` | password fallback |
| authentication failed | `failed` | password fallback |
| other error | `failed` | password fallback |

## Important limitation: macOS password fallback

The project requirement is:

- Apple Watch / Touch ID approval when available
- Linux password fallback when Apple Watch / Touch ID is unavailable

It is **not** a goal for the macOS account password to approve Linux `sudo`.

Apple's LocalAuthentication policies can have subtle password fallback behavior depending on policy and OS version. The current implementation uses biometric/watch/companion policies, but behavior must be tested on each supported macOS version.

If a macOS policy allows macOS password fallback in a way that cannot be disabled, this must be documented clearly and may require changing policy or treating that OS version as unsupported for strict mode.

## Confirmation UI vs LocalAuthentication prompt

LocalAuthentication prompts often have limited context, especially on Apple Watch.

For this reason, the agent shows an explicit confirmation alert before LocalAuthentication by default. It includes:

- Linux hostname
- Linux host id
- PAM service
- PAM user
- requester, if available
- TTY, if available
- command, if available
- request id

This confirmation is controlled by:

```json
{
  "require_confirmation": true
}
```

Disabling it is not recommended outside development.

## Apple Watch behavior

Apple Watch approval details may vary by:

- macOS version
- watchOS version
- whether Auto Unlock is enabled
- whether the watch is unlocked and on wrist
- whether the Mac considers the watch a companion device
- hardware model

The project currently treats LocalAuthentication success as approval and does not distinguish whether success came from Touch ID or Apple Watch.

The response `auth_method` is currently `biometric-or-watch` for approved LocalAuthentication.

## Testing matrix

Before claiming support for a macOS version, test:

| Scenario | Expected decision |
|---|---|
| Touch ID success | `approved` |
| Apple Watch success | `approved` |
| user cancels confirmation alert | `cancelled` |
| user cancels LocalAuthentication | `cancelled` |
| watch unavailable | `unavailable` |
| Touch ID not enrolled | `unavailable` |
| repeated biometric failure | `failed` or `unavailable`, depending on OS lockout behavior |
| invalid Linux host signature | no UI, no LocalAuthentication prompt |
| unlisted Linux host id | no UI, no LocalAuthentication prompt |

## Prompt rate limiting

The agent has an in-memory per-host/service/user rate limiter. It is evaluated only after request signature and allowlist verification, and before confirmation UI / LocalAuthentication.

Default config:

```json
{
  "rate_limit_window_seconds": 60,
  "rate_limit_max_requests": 5
}
```

If the limit is exceeded, the agent returns a signed `cancelled` response with `auth_method = none`, so Linux falls back to password by default. This avoids showing additional prompts during a burst.

The rate limiter is currently in-memory and resets when the agent restarts.

## Known implementation gaps

- The agent does not yet distinguish Touch ID approval from Apple Watch approval.
- The agent does not yet expose a strict mode to reject macOS password fallback if the OS offers it.
- The agent has no per-OS compatibility table yet.
- The confirmation UI is a basic `NSAlert`.
- No automated UI tests exist.

## Future hardening

Potential improvements:

- record the evaluated biometry type when available
- add a strict mode for policies that never allow macOS password fallback, if possible
- add OS compatibility documentation based on real testing
- improve the confirmation UI
- add prompt rate limiting
- add telemetry-free local logs for LocalAuthentication error codes
