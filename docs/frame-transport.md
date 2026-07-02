# Frame transport specification

This document specifies the current development frame transport used between `macos-auth-helper` and `macos-auth-agent`.

The current transport is intentionally simple and may be replaced by a stricter binary encoding in the future.

## Scope

This document covers only the local IPC frame format over Unix domain sockets.

It does not define the signed canonical bytes. Signature input is defined by the protocol structures in Rust/Swift and summarized in `docs/protocol.md`.

## Current frame format

Each message is sent as:

```text
uint32_be payload_length
payload_length bytes of UTF-8 JSON
```

Where:

- `payload_length` is a 4-byte unsigned big-endian integer
- maximum accepted payload length is `1 MiB`
- payload is JSON encoded request or response structure

## Maximum frame size

Current limit:

```text
1 MiB = 1024 * 1024 bytes
```

Frames larger than this must be rejected before allocation of the full payload.

## JSON role

JSON is transport/debug encoding only.

JSON bytes are **not** signed directly.

Instead:

1. JSON is decoded into typed request/response structures.
2. The implementation reconstructs canonical signing bytes from typed fields.
3. Signatures are verified over canonical bytes.

This prevents JSON key ordering, whitespace, and serializer differences from affecting signature verification.

## Expected payloads

Linux helper -> macOS agent:

```text
SignedAuthRequest
```

macOS agent -> Linux helper:

```text
SignedAuthResponse
```

Unknown schemas, missing fields, wrong field types, invalid enum values, or malformed JSON must be rejected.

## Error handling

### Helper side

If the helper cannot connect to the socket:

```text
exit 10  # unavailable / password fallback
```

If the helper connects but receives malformed protocol data:

```text
exit 32  # protocol error / hard fail
```

If the helper receives a well-formed but invalidly signed or mismatched response:

```text
exit 30  # tamper / hard fail
```

### Agent side

If the agent receives an invalid request:

- it must not show confirmation UI
- it must not invoke LocalAuthentication
- it may close the connection without response
- it should log a non-sensitive error

## Negative test coverage

The Rust helper currently has unit tests for:

- oversized frame
- truncated length prefix
- truncated body
- invalid JSON
- wrong schema
- valid round-trip

Full fuzzing is still pending.

## Security notes

- The frame transport is not a trust boundary.
- Unix socket permissions are defense-in-depth only.
- Authenticity and integrity come from request/response signatures.
- Response binding and freshness are checked after frame decoding.

## Future migration options

Possible future transports:

1. Canonical CBOR
2. MessagePack with strict canonical rules
3. custom binary structure
4. length-prefixed canonical protocol bytes rather than JSON

A future transport should preserve:

- explicit maximum frame size
- strict schema validation
- cross-language test vectors
- no algorithm negotiation with untrusted peers
- no generic signing API

## Compatibility

The current frame format is development protocol behavior. Do not treat it as a stable public API until the project has versioned releases.
