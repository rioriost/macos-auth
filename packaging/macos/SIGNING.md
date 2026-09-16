# macOS signing and notarization

This document describes the manual preparation needed for Homebrew cask distribution.

## Required Apple assets

You need access to an Apple Developer Program team and these certificates in the login keychain:

- `Developer ID Application: ... (TEAMID)`
- `Developer ID Installer: ... (TEAMID)`

Check available identities:

```text
security find-identity -v -p codesigning
security find-identity -v | grep 'Developer ID Installer'
```

## Notary credential setup

Create an app-specific password for the Apple ID, then store notary credentials once:

```text
xcrun notarytool store-credentials macos-auth-notary \
  --apple-id APPLE_ID \
  --team-id TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

If the app-specific password is already stored as a generic password in Keychain, retrieve it with `security find-generic-password` and pass it to `notarytool`. Example:

```text
APP_SPECIFIC_PASSWORD=$(security find-generic-password -s KEYCHAIN_ITEM_SERVICE -a APPLE_ID -w)

xcrun notarytool store-credentials macos-auth-notary \
  --apple-id APPLE_ID \
  --team-id TEAM_ID \
  --password "$APP_SPECIFIC_PASSWORD"
```

Validate the profile:

```text
xcrun notarytool history --keychain-profile macos-auth-notary
```

## Build a signed package
Use a Developer ID Application certificate for the agent binary and a Developer ID Installer certificate for the pkg:

```text
packaging/macos/build-pkg.sh \
  --sign-identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --pkg-sign-identity "Developer ID Installer: YOUR NAME (TEAMID)"
```

Use matching Application and Installer identities available to the local builder.
Release builds require clean committed source, Git, tar, Python 3.9+, and a package
version matching the committed helper manifest. Unsigned `--development` builds
cannot be notarized or promoted.

Expected output:

```text
target/package/macos/macos-auth-0.1.2-darwin-arm64-signed.pkg
```

The agent binary is signed with hardened runtime before it is packaged. The installer package is then signed with the Developer ID Installer identity.

## Notarize and staple

```text
packaging/macos/notarize-pkg.sh \
  --pkg target/package/macos/macos-auth-0.1.2-darwin-arm64-signed.pkg \
  --keychain-profile macos-auth-notary \
  --final-pkg target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg \
  --sha256-file target/package/macos/SHA256SUMS.cask
```

The wrapper validates the signed artifact's `.metadata.json` and `.sha256`
sidecars before submission. It staples an isolated copy, checks the ticket,
signature, and Gatekeeper, then records the final bytes and their signed-input
provenance. The original signed package/sidecars are not modified. Existing final
outputs are refused; use a fresh directory for repeat builds.

## Verify

```text
xcrun stapler validate target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg
pkgutil --check-signature target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg
spctl --assess --type install -vv target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg
```

Also verify the installed binary signature after a local install:

```text
codesign --verify --strict --verbose=2 /opt/homebrew/bin/macos-auth-agent
codesign -dv --verbose=4 /opt/homebrew/bin/macos-auth-agent
```

## Release asset naming

For cask use, the wrapper writes:

```text
macos-auth-0.1.2-darwin-arm64.pkg
```

Use the hash in `SHA256SUMS.cask` for the cask. It can also be checked with:

```text
shasum -a 256 macos-auth-0.1.2-darwin-arm64.pkg
```

Do not manually rename or staple recorded artifacts: doing so invalidates their
metadata/checksums. Transfer the final package and its two sidecars together.
