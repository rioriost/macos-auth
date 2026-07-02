# Keychain and Secure Enclave notes

This document explains the current macOS agent key storage model and the gap between the development Keychain implementation and the desired production-grade non-exportable key storage.

## Current implementation

The macOS agent can use these key sources:

1. inline `agent_key_hex`, development only
2. file-backed `agent_key_file`, development only
3. Keychain generic-password item, preferred for development

The recommended development config is:

```json
{
  "agent_keychain_service": "com.macos-auth.agent",
  "agent_keychain_account": "default"
}
```

Create the Keychain item with:

```text
macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default
```

Export the public key with:

```text
macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default
```

## What the current Keychain storage does

The current implementation stores raw `Curve25519.Signing.PrivateKey` bytes in a Keychain generic-password item.

It sets:

```text
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

This means:

- the item is only available on this device
- it is not intended to migrate through backups
- it is available after the first unlock after boot

## What it does not do

The current implementation does **not** make the key non-exportable.

The agent process can read raw private key bytes from Keychain and construct a `Curve25519.Signing.PrivateKey` in memory.

Therefore, this is not equivalent to a Secure Enclave key.

## Why Keychain generic-password storage is still useful

It is better than inline or file-backed keys because:

- private key material is no longer stored directly in JSON config
- file permission mistakes are less likely
- the item is stored in macOS Keychain
- `ThisDeviceOnly` reduces accidental migration

However, it is still a development-grade storage mechanism.

## Desired production direction

The desired production direction is a non-exportable signing key, ideally backed by Secure Enclave.

Properties desired:

- private key cannot be exported by the agent process
- signing operation can be gated by user presence / biometric policy if possible
- public key can be exported for Linux helper pinning
- signing algorithm is pinned in config / protocol

## Secure Enclave algorithm issue

The current protocol uses Ed25519 / Curve25519 signing keys.

Apple Secure Enclave support may require a different algorithm, commonly P-256 ECDSA through Security.framework / CryptoKit APIs.

If Secure Enclave cannot support Ed25519 signing, the protocol needs algorithm agility.

Potential future algorithms:

- `Ed25519`, current development protocol
- `P256-SHA256`, likely Secure Enclave-compatible candidate

## Protocol changes needed for Secure Enclave

Before adding P-256 or another algorithm, the protocol should define:

- canonical algorithm names
- signature encoding format
- public key encoding format
- key id and algorithm pinning
- cross-language test vectors
- downgrade resistance

Important rule:

The algorithm must be pinned by configuration and included in signed payloads. The system should not negotiate algorithms dynamically with an untrusted peer.

## Keychain access control considerations

Future Keychain/Secure Enclave work should evaluate:

- `SecAccessControlCreateWithFlags`
- `.privateKeyUsage`
- `.biometryCurrentSet`
- `.userPresence`
- `.watch` / companion-related availability, if exposed
- whether LocalAuthentication context can be bound to signing
- behavior when biometric enrollment changes
- behavior after reboot before first unlock
- behavior in LaunchAgent vs GUI app contexts

## Current operational recommendations

For development:

- Prefer Keychain generic-password storage over `agent_key_hex`.
- Avoid inline private key material in config.
- Avoid committing config files containing private material.
- Keep `require_confirmation=true`.
- Use host allowlists.

Do not claim production-grade key protection until non-exportable signing is implemented and reviewed.

## Migration path

A likely migration path:

1. keep current Ed25519 file/Keychain support for development
2. add protocol enum support for P-256 signatures
3. add deterministic P-256 test vectors
4. add Secure Enclave key generation command
5. add public key export command
6. add signing path that uses Secure Enclave without exporting private material
7. update Linux verifier to support pinned P-256 agent keys
8. deprecate inline `agent_key_hex`

## Related design note

See `docs/protocol-v2-p256.md` for a possible protocol extension to support P-256 / Secure Enclave backed signing.

## Open questions

- Can Apple Watch / companion approval be required directly for Secure Enclave signing?
- Can a single LocalAuthentication approval be safely reused for signing the response only?
- Which macOS versions support the required access control flags?
- How should P-256 signatures be encoded for deterministic verification across Rust and Swift?
- Should Linux host keys also support P-256 for symmetry, or only macOS agent keys?
