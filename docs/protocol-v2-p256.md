# Protocol v2 / P-256 Secure Enclave feasibility note

This document sketches a possible protocol extension for Secure Enclave backed macOS agent signing.

It is not implemented yet.

## Motivation

The current protocol uses Ed25519 / Curve25519 signing keys.

This is simple and works across Rust and Swift, but the current macOS Keychain support stores raw Curve25519 private key bytes as a generic-password item. The agent process can read/export those bytes.

For production-grade macOS agent keys, the desired property is non-exportability. On Apple platforms, that likely means Secure Enclave backed keys.

Secure Enclave commonly supports P-256 keys, not Ed25519 signing keys. Therefore, a future protocol version may need P-256 ECDSA support.

## Goals

- Support non-exportable macOS agent signing keys where possible.
- Keep Linux host Ed25519 keys working initially.
- Pin algorithms by config; do not negotiate algorithms dynamically.
- Preserve request/response binding semantics.
- Preserve cross-language deterministic verification tests.
- Avoid downgrade attacks.

## Non-goals

- Replacing all host keys with P-256 immediately.
- Runtime negotiation with untrusted peers.
- Supporting arbitrary algorithm lists.
- Changing transport semantics.

## Current v1 algorithm model

Current v1 payloads contain:

```text
alg = ed25519
```

Rust serializes the enum as `ed25519` in JSON, while canonical signing bytes encode `Ed25519`.

This mismatch is handled explicitly in Swift by canonicalizing the algorithm name during signature verification.

## Proposed v2 algorithm names

Canonical algorithm names should be exact and stable:

| JSON value | canonical signing name | meaning |
|---|---|---|
| `ed25519` | `Ed25519` | current v1 Ed25519 signature |
| `p256-sha256` | `P256-SHA256` | ECDSA P-256 over SHA-256 |

The canonical name must be included in signed bytes.

## Signature encoding

For P-256 ECDSA, signature encoding must be specified.

Options:

1. ASN.1 DER ECDSA signature
2. raw fixed-width `r || s`, 32 bytes each

Recommendation:

- Use raw `r || s` if both Rust and Swift can produce/consume it reliably.
- Otherwise use DER but include test vectors to avoid ambiguity.

Open question:

- CryptoKit `P256.Signing.ECDSASignature` supports both `derRepresentation` and `rawRepresentation`; Rust verifier choice should match exactly.

## Public key encoding

For P-256 public keys, choose one encoding:

1. SEC1 compressed point
2. SEC1 uncompressed point
3. X9.63 representation

Recommendation:

- Use X9.63 uncompressed representation if CryptoKit and Rust verifier support it easily.
- Encode as hex in config/public key files, same as Ed25519.

## Payload changes

Minimal payload changes:

- Keep `protocol_version = 1` if only adding algorithm enum support and semantics remain identical.
- Use `protocol_version = 2` if canonical bytes or required fields change.

Safer approach:

- Introduce `protocol_version = 2` for P-256 support.
- Keep v1 Ed25519 verifier for compatibility.

Potential v2 fields:

```text
protocol_version = 2
alg = p256-sha256
key_id = agent-secure-enclave-p256-1
```

The response signing algorithm is most important for Secure Enclave. Linux host request signing can remain Ed25519 at first.

## Configuration model

Linux helper should pin the agent algorithm with the public key.

Example future config:

```toml
[[agents]]
user = "alice"
key_id = "agent-secure-enclave-p256-1"
alg = "p256-sha256"
public_key_file = "/etc/macos-auth/agents.d/alice-p256.pub"
```

macOS agent config:

```json
{
  "agent_key_source": "secure-enclave",
  "agent_key_id": "agent-secure-enclave-p256-1",
  "agent_alg": "p256-sha256"
}
```

## Downgrade resistance

Rules:

- The Linux helper must know the expected algorithm for the pinned agent key.
- The macOS agent response must include `alg` and `agent_key_id` in signed bytes.
- The Linux helper must reject a response signed with a different algorithm than configured.
- Do not accept peer-provided algorithm negotiation.

## Secure Enclave command sketch

Potential future commands:

```text
macos-auth-agent secure-enclave-init \
  --label com.macos-auth.agent.default \
  --access-control user-presence

macos-auth-agent secure-enclave-public-key \
  --label com.macos-auth.agent.default
```

Potential config:

```json
{
  "agent_key_source": "secure-enclave",
  "agent_key_label": "com.macos-auth.agent.default",
  "agent_alg": "p256-sha256"
}
```

## LocalAuthentication interaction

Two possible designs:

### Separate approval then sign

1. Use LocalAuthentication for Apple Watch / Touch ID approval.
2. If approved, ask Secure Enclave key to sign.

Question:

- Can signing occur without another prompt?
- Is the signature operation sufficiently bound to the prior LA approval?

### Secure Enclave signing gated by access control

1. Request Secure Enclave signature.
2. Key access control triggers user presence / biometry.

Question:

- Can Apple Watch / companion satisfy the access control?
- Can the prompt display enough request context?

Likely initial approach:

- Keep explicit confirmation UI.
- Use LocalAuthentication approval.
- Use Secure Enclave key for non-exportable signing.
- Accept that OS may show an additional key access prompt until tested.

## Rust implementation considerations

Potential crates:

- `p256`
- `ecdsa`
- `sha2`

Verifier requirements:

- parse public key representation
- parse signature representation
- verify exact canonical response bytes
- expose deterministic test vectors

## Swift implementation considerations

Potential APIs:

- `SecureEnclave.P256.Signing.PrivateKey`
- `P256.Signing.PublicKey`
- Keychain `SecKey` APIs if CryptoKit is insufficient

Need to test:

- key generation under LaunchAgent
- public key export
- signing while user session is active
- behavior after reboot
- behavior with watch/biometry unavailable
- access control prompts

## Test vectors

Before merging P-256 support, add:

- deterministic software P-256 vector for Rust/Swift canonical verification
- Secure Enclave generated vector cannot be deterministic, but verifier should still validate exported public key + signature fixtures
- negative vectors:
  - wrong algorithm
  - wrong key id
  - DER/raw mismatch
  - modified response body

## Migration plan

1. Add algorithm enum support in Rust and Swift.
2. Add P-256 software verification path.
3. Add P-256 test vectors.
4. Add macOS Secure Enclave key generation / public key export.
5. Add macOS Secure Enclave response signing.
6. Add Linux helper config for algorithm-pinned agent keys.
7. Mark Ed25519 Keychain generic-password storage as development-only.

## Open questions

- Can Secure Enclave signing be made to require Apple Watch / companion specifically?
- Which access control flags are available and reliable across macOS versions?
- Is P-256 raw signature encoding acceptable across Rust and Swift without ambiguity?
- Should v2 also move transport away from JSON frames?
- Should Linux host keys also support P-256 or remain Ed25519?
