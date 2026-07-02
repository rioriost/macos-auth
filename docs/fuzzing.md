# Fuzzing

This project includes a `cargo-fuzz` skeleton for protocol JSON decoding and canonical byte reconstruction.

Fuzzing is not yet part of default CI.

## Install cargo-fuzz

```text
cargo install cargo-fuzz
```

## Fuzz targets

### Signed response JSON

```text
cargo fuzz run signed_response_json
```

This target:

1. treats fuzzer input as JSON
2. attempts to decode `SignedAuthResponse`
3. reconstructs canonical response bytes if decoding succeeds

### Signed request JSON

```text
cargo fuzz run signed_request_json
```

This target:

1. treats fuzzer input as JSON
2. attempts to decode `SignedAuthRequest`
3. reconstructs canonical request bytes if decoding succeeds

## Current limitations

- Frame length-prefix parsing is not yet fuzzed directly because the frame helpers currently live inside the helper binary.
- The fuzz targets do not verify signatures; they focus on parser/canonicalization robustness.
- No corpus is checked in yet.

## Future fuzz targets

Planned targets:

- length-prefixed frame decoder
- helper config TOML parser
- key material parser
- response binding verification
- Swift-side decoder equivalents if a Swift fuzzing setup is added
