# macOS LocalAuthentication notes

`macos-auth-agent serve` uses Apple's `LocalAuthentication.framework` to ask the local macOS user to approve a verified Linux PAM request.

This document records current assumptions, limitations, and testing requirements.

## Current implementation

The agent selects the policy by macOS version:

| macOS version | Policy |
|---|---|
| macOS 15+ | `deviceOwnerAuthenticationWithBiometricsOrCompanion` |
| macOS 13–14 | `deviceOwnerAuthenticationWithBiometricsOrWatch` |

The agent flow is:

1. verify Linux host allowlist
2. verify request signature
3. verify request freshness
4. show confirmation UI if `require_confirmation=true` (default: `false`)
5. call `LAContext.canEvaluatePolicy`
6. call `LAContext.evaluatePolicy`
7. map the result to a signed response decision

The Swift package requires macOS 13 or later.

## Request lifetime and concurrency

Both `serve` and `fake-agent` admit at most eight active connections. Excess
connections are closed rather than queued in unbounded background work. A client
has an absolute two-second frame-read budget (header and body combined), within
a fifteen-second total connection budget starting at acceptance. Partial reads
and writes do not reset these deadlines.

Verified requests share one authentication slot. Waiting for that slot, optional
confirmation, LocalAuthentication, and response writing all count against the
earlier of the connection deadline and the signed request expiry. The agent also
checks wall-clock expiry, while monotonic deadlines prevent a backward clock
adjustment from extending a request.

While waiting or authenticating, the agent checks expiry and peer disconnect
about every 25 ms. Cancellation invalidates the `LAContext`; a confirmation alert
has a modal-run-loop timer that dismisses it on cancellation. AppKit and
LocalAuthentication initiation run on the main thread. Late callbacks cannot
produce an approval: the lifetime is rechecked before constructing and sending
the signed response, whose expiry never exceeds the request expiry.

The helper's signed request expiry must match its total timeout (normally 15
seconds), inside PAM's outer timeout (normally 20 seconds). The agent does not
extend a nearly expired request to give a response extra time. Expired,
disconnected, or overloaded connections are closed without approval. Unix socket
writes use `SO_NOSIGPIPE`, so a disconnected peer cannot terminate the agent.

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

For more context, enable the optional explicit confirmation alert before
LocalAuthentication. It includes:

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

The default is intentionally `false`: the LocalAuthentication prompt is still
required, but the extra confirmation alert is skipped. Set this to `true` when
the additional host/user/command context is desired. Its time counts against the
same request deadline; it does not grant a separate approval window.

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
| request expires during confirmation or LocalAuthentication | dismiss/invalidate; no approval |
| helper disconnects during confirmation or LocalAuthentication | dismiss/invalidate; no approval |
| a callback arrives after cancellation | ignored for approval |
| idle or partial-frame client, followed by a valid client | valid client can proceed within connection limits |

`swift test --package-path agent` covers transport deadlines, disconnected writes,
bounded admission, queued authentication expiry, cancellation/late callback
handling, modal-panel-mode cancellation timer delivery, filesystem safety, and protocol vectors without biometric UI or
Keychain access. It uses mock authentication sessions and injectable clocks;
the fake-agent subprocess integration uses only fixed development keys and
disposable fixtures under `agent/`. Actual alert dismissal and OS-provided
LocalAuthentication behavior still require the manual matrix above.

### Recorded compatibility checks

- [macOS 27.2 beta 2, 2026-09-27](macos-27.2-beta2-compatibility.md):
  automated checks, builds, cross-language runtime checks, and capability probes
  passed. Actual Touch ID / Apple Watch approval and OS password fallback remain
  unverified.

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
- add telemetry-free local logs for LocalAuthentication error codes
