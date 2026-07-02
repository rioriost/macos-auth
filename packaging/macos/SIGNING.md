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

For this project owner, the currently observed Developer ID Application identity is:

```text
Developer ID Application: Ryo Fujita (23889H77KX)
```

A matching `Developer ID Installer: Ryo Fujita (23889H77KX)` identity is also required for cask-ready `.pkg` signing.

Expected output:

```text
target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
```

The agent binary is signed with hardened runtime before it is packaged. The installer package is then signed with the Developer ID Installer identity.

## Notarize and staple

```text
xcrun notarytool submit target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg \
  --keychain-profile macos-auth-notary \
  --wait

xcrun stapler staple target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
```

## Verify

```text
pkgutil --check-signature target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
spctl --assess --type install -vv target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
```

Also verify the installed binary signature after a local install:

```text
codesign --verify --strict --verbose=2 /opt/homebrew/bin/macos-auth-agent
codesign -dv --verbose=4 /opt/homebrew/bin/macos-auth-agent
```

## Release asset naming

For cask use, copy or rename the signed and stapled package to:

```text
macos-auth-0.1.0-darwin-arm64.pkg
```

Then compute:

```text
shasum -a 256 macos-auth-0.1.0-darwin-arm64.pkg
```

Use that checksum in the cask.
