# Protocol notes

The initial implementation uses explicit canonical signing bytes rather than signing JSON directly.

Each signed structure is encoded in a fixed field order using:

- domain separation string
- big-endian integers
- `u32` length-prefixed byte strings
- explicit presence bytes for optional fields

This avoids relying on JSON object key ordering or cross-language serializer behavior for signatures.

JSON is currently only used as a human-readable transport/debug representation for early test fixtures. The signed bytes are produced by `AuthRequestBody::canonical_bytes()` and `AuthResponseBody::canonical_bytes()` in `crates/protocol`.

Security invariants implemented first:

- request signatures bind host id, PAM service, PAM user, tty, nonce, and validity window
- response signatures bind request id, nonce, request hash, host id, PAM service, PAM user, decision, method, and validity window
- response verification checks both signature validity and binding to the original request

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
