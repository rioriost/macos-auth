# macOS 27.2 beta 2 compatibility check

## Summary

The automated checks completed successfully on 2026-09-27 (JST). No compatibility
issue was detected within the tested scope. This is not a full macOS support
certification: actual Touch ID / Apple Watch approval and OS-provided fallback
behavior were not tested.

## Environment

| Item | Observed value |
|---|---|
| Tested source commit | `336cad62ed9674ea7c995e3e7bd8206cd2a0429c` |
| Hardware | MacBook Air, model identifier `Mac15,12` |
| Architecture | `arm64` |
| macOS version (`sw_vers`) | `27.2` |
| macOS build (`sw_vers`) | `26B5091g` |
| Release label | beta 2, as reported by the operator |
| Active developer directory | `/Applications/Xcode.app/Contents/Developer` |
| macOS SDK | `27.0` |
| Swift | `6.4` (`swiftlang-6.4.0.34.1`) |
| Apple Clang | `21.0.0` (`clang-2100.3.34.2`) |
| Rust / Cargo | `1.85.0` / `1.85.0` |
| Python | `3.14.7` |

## Automated checks and builds

Commands executed from the repository root:

```sh
make check
make build
swift build -c release --package-path agent
agent/.build/release/macos-auth-agent verify-vector --path test-vectors/v1/approval.json
```

| Check | Result |
|---|---|
| Rust formatting | Passed |
| Rust tests | 47 passed, 0 failed, 0 ignored |
| PAM C syntax and unit tests | Passed; no live PAM configuration used |
| Swift agent tests | 30 passed, 0 failed |
| Debug agent approval-vector verification | Passed |
| Python setup tests | 7 passed |
| Python release-packaging tests | 46 passed |
| Shell syntax checks | Passed |
| Rust helper and PAM module builds | Passed |
| Swift debug and release builds | Passed |
| Release agent approval-vector verification | Passed |

The Rust, Swift, and Python suites totaled 130 passing tests, in addition to the
PAM unit-test runner. The generated helper and release agent were Mach-O `arm64`
executables; the PAM module was a Mach-O `arm64` bundle.

## Cross-language runtime checks

An additional local harness used the release Swift `fake-agent --once` and the
debug Rust helper's `request` command over a real Unix domain socket. It used
fixed development keys from `test-vectors/v1/approval.json`, disposable
project-local files, and a helper timeout of 3,000 ms. It did not invoke
LocalAuthentication or PAM.

| Scenario | Expected helper exit | Observed result |
|---|---|---|
| Signed `approved` response | `0` | Passed |
| Signed `denied` response | `20` | Passed |
| Signed `unavailable` response | `10` | Passed |
| Signed `cancelled` response | `11` | Passed |
| Signed `failed` response | `12` | Passed |
| Response checked against the wrong pinned agent public key | `30` | Passed |
| Missing agent socket | `10` | Passed |

All seven checks passed. Each of the six agent processes exited with status `0`
and removed its socket. Disposable fixtures were cleaned up.

## LocalAuthentication capability probe

A separate Swift probe called `LAContext.canEvaluatePolicy` with the agent's
cancel and fallback titles. It did not call `evaluatePolicy` or show authentication
UI.

| Policy / capability | Observed result |
|---|---|
| `deviceOwnerAuthenticationWithBiometricsOrCompanion` (agent policy) | Available |
| `deviceOwnerAuthenticationWithBiometrics` | Available |
| `deviceOwnerAuthenticationWithCompanion` | Available |
| `LAContext.biometryType` | `touchID` (raw value `1`) |
| `SecureEnclave.isAvailable` | `true` |

Capability availability does not establish successful authentication. In
particular, Companion availability does not verify Apple Watch approval, and
Secure Enclave availability does not verify key creation or signing.

## Not tested

- Actual Touch ID or Apple Watch approval.
- Actual confirmation / LocalAuthentication UI cancellation, expiry, or
  disconnect behavior; automated coverage uses mock authentication.
- macOS account-password fallback behavior or strict-mode suitability.
- Unavailable or locked-out biometric / companion hardware scenarios.
- Keychain reads or writes, or Secure Enclave key creation / signing.
- Live LaunchAgent installation, package installation, signing, or notarization.
- SSH forwarding to Linux or authentication through a live Linux PAM stack.

The verification did not change tracked source files, PAM configuration,
Keychain items, or installed background services. Build outputs were retained.
Complete the [manual authentication matrix](macos-local-authentication.md#testing-matrix)
before claiming full support for this OS version.
