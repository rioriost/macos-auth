# Protocol notes

The initial implementation uses explicit canonical signing bytes rather than signing JSON directly.

Each signed structure is encoded in a fixed field order using:

- domain separation string
- big-endian integers
- `u32` length-prefixed byte strings
- explicit presence bytes for optional fields

This avoids relying on JSON object key ordering or cross-language serializer behavior for signatures.

JSON is the current framed wire representation as well as a human-readable fixture
format. JSON text is not signed directly. The signed bytes are produced by
`AuthRequestBody::canonical_bytes()` and `AuthResponseBody::canonical_bytes()` in
`crates/protocol`, with matching typed Swift encoders.

Security invariants implemented first:

- request signatures bind host id, PAM service, PAM user, tty, nonce, and validity window
- response signatures bind request id, nonce, request hash, host id, PAM service, PAM user, decision, method, and validity window
- response verification checks both signature validity and binding to the original request

## Version 1 enum encoding

Decisions are typed values: `approved`, `denied`, `unavailable`, `cancelled`, and
`failed`. Their JSON and canonical spellings are identical.

Authentication methods have one intentional wire/canonical difference:

| JSON `auth_method` | Canonical signing string |
|---|---|
| `watch` | `watch` |
| `touch-id` | `touchid` |
| `biometric-or-watch` | `biometric-or-watch` |
| `unknown` | `unknown` |
| `none` | `none` |

In particular, **do not sign the JSON spelling `touch-id` directly**. Both
implementations reject unknown decision/method strings during typed decoding.
The algorithm's JSON spelling is `ed25519`, while its canonical string is
`Ed25519`. This preserves the existing v1 contract rather than changing the wire
format or protocol version.

## Request and response lifetime

The signed request expiry must fit the helper's total operation deadline,
including connection, request write, and response read (default: 15 seconds).
The macOS agent caps each accepted connection at 15 seconds, reads its initial
frame within two seconds, and never extends that budget on partial I/O.
Authentication queueing and any confirmation alert use the same lifetime.

The agent rejects requests at or after their expiry. It invalidates pending
authentication on expiry or peer disconnect and checks lifetime again before
signing/sending. Responses expire no later than the request, even when the
ordinary ten-second response validity window would extend beyond it. Late
authentication success cannot create a fresh approval window.

## Test vectors

`test-vectors/v1/approval.json` is a deterministic approval vector using fixed development keys:

- host private key: `07` repeated 32 bytes
- agent private key: `09` repeated 32 bytes
- nonce: `42` repeated 32 bytes
- request id: `req-test-vector-v1`

The vector is generated with:

```text
cargo run -p macos-auth-helper -- test-vector > test-vectors/v1/approval.json
```

Rust verifies the vector in `macos-auth-protocol` unit tests. Swift verifies it with:

```text
agent/.build/debug/macos-auth-agent verify-vector --path test-vectors/v1/approval.json
```

`test-vectors/v1/response-enums.json` contains all 25 decision/method combinations
as full signed response objects, bound to the same request, keys, and timestamps
as `approval.json`. These are interoperability fixtures, not a policy assertion
that every combination is emitted by a real authenticator. Swift's automated
tests check the complete Cartesian set, canonical bodies, JSON round-trips, and
signatures. The Rust protocol tests verify the same fixtures.

To regenerate the enum fixture explicitly using the development key:

```text
UPDATE_PROTOCOL_VECTORS=1 swift test --package-path agent --filter AgentTests.testEveryDecisionAndMethodVector
```

CryptoKit may randomize Ed25519 signing, so regenerated signatures need not be
byte-identical. Verification and canonical-body equality, not re-signing equality,
are the interoperability checks. These fixed development keys must never be used
for production authentication.

## Early helper transport

The current frame transport is specified in `docs/frame-transport.md`.

`macos-auth-helper request` and `macos-auth-helper fake-agent` currently use a simple length-prefixed JSON frame over Unix domain sockets:

1. 4-byte big-endian frame length
2. UTF-8 JSON payload

This is intentionally an early integration-test transport. The JSON payload contains signed request/response objects, but JSON bytes are not themselves trusted as canonical signing bytes. The verifier reconstructs canonical bytes from the typed payload and verifies Ed25519 signatures over those canonical bytes.

The Rust helper includes negative tests for oversized frames, truncated frames, invalid JSON, wrong schema, and round-trip frame decoding. Full fuzzing is still pending.

Helper exit codes currently reserve the PAM-facing semantics planned for the C shim:

| exit code | meaning |
|---:|---|
| 0 | approved |
| 10 | unavailable; PAM should fall back to password |
| 11 | cancelled; PAM should fall back to password by default |
| 12 | biometric/auth failed; PAM should fall back to password |
| 20 | denied; policy-dependent |
| 30 | tamper/signature/binding/freshness failure; PAM should hard fail |
| 31 | unsafe config, including permissive private key file permissions; PAM should hard fail |
| 32 | protocol error after connecting; PAM should hard fail |
