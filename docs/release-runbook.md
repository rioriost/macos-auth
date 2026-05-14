# Release runbook

This document maps the release process to reproducible `make` targets and scripts.

## Status

The release is reproducible from scripted steps, but it is intentionally split by builder type:

- macOS package build/sign/notarize runs on the Apple Silicon Mac.
- Linux x86_64 packages are built in clean Podman containers on an x86_64 Linux host.
- Linux arm64/aarch64 packages are built natively on the relevant arm64/aarch64 Linux builders.
- GitHub draft release upload runs from a machine with `gh` authentication.
- Homebrew cask update is in the separate `../homebrew-cask/` repository.

Do not hardcode private builder hostnames, LAN IP addresses, SSH usernames, signing passwords, or Apple credentials in this repository.

## Common variables

```text
VERSION=0.1.0
RELEASE_TAG=v0.1.0
RELEASE_REPO=rioriost/macos-auth
SOURCE_COMMIT=$(git rev-parse HEAD)
```

## Linux package builds

### Native `.deb`

Run on the target Debian/Ubuntu builder:

```text
make check
make package-deb
```

Output:

```text
target/package/deb/macos-auth_0.1.0_<arch>.deb
```

### Native `.rpm`

Run on the target RHEL-family builder:

```text
make check
make package-rpm
```

Output:

```text
target/package/rpm/macos-auth-0.1.0-1.<dist>.<arch>.rpm
```

### x86_64 clean container build

Run on an x86_64 host with Podman:

```text
make package-x86_64-containers
```

Output:

```text
target/package/x86_64-containers/
```

## macOS package build

Unsigned local package:

```text
make package-macos
```

Signed package:

```text
make package-macos-signed \
  CODESIGN_IDENTITY="Developer ID Application: Ryo Fujita (23889H77KX)" \
  PKG_SIGN_IDENTITY="Developer ID Installer: Ryo Fujita (23889H77KX)"
```

Notarize, staple, verify, and write the cask-named package:

```text
make notarize-macos NOTARY_PROFILE=macos-auth-notary
```

Output:

```text
target/package/macos/macos-auth-0.1.0-darwin-arm64.pkg
target/package/macos/SHA256SUMS.cask
```

## Assemble release directory

Create a release directory containing:

- all Linux `.deb` / `.rpm` artifacts
- macOS `.pkg`
- `SHA256SUMS`
- `SHA256SUMS-darwin-arm64`
- `BUILD-METADATA.txt`
- `BUILD-METADATA-darwin-arm64.txt`

The exact copy/scp step depends on local builder inventory, so it is intentionally not hardcoded here. Store local inventory in `docs/build-farm.local.md` or shell aliases outside git.

Suggested output directory:

```text
target/package/release/
```

## Generate release notes

```text
make release-notes VERSION=0.1.0 SOURCE_COMMIT=$(git rev-parse HEAD)
```

Output:

```text
target/package/release/RELEASE-NOTES.md
```

Edit the generated checklist from `[ ]` to completed validation notes before publishing.

## Upload/update GitHub draft release

```text
make release-upload-draft \
  VERSION=0.1.0 \
  RELEASE_TAG=v0.1.0 \
  RELEASE_REPO=rioriost/macos-auth \
  SOURCE_COMMIT=$(git rev-parse HEAD) \
  RELEASE_DIR=target/package/release \
  RELEASE_NOTES=target/package/release/RELEASE-NOTES.md
```

This creates or updates a draft release and uploads matching assets. Existing assets with the same names are overwritten.

Check status:

```text
make release-status VERSION=0.1.0 RELEASE_REPO=rioriost/macos-auth
```

## Homebrew cask update

The cask lives in `../homebrew-cask/`.

After the macOS package is notarized:

1. Copy the SHA256 from `target/package/macos/SHA256SUMS.cask`.
2. Update `../homebrew-cask/Casks/macos-auth.rb`.
3. Run:

```text
HOMEBREW_NO_AUTO_UPDATE=1 brew style --cask rioriost/cask/macos-auth
HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask rioriost/cask/macos-auth
```

The cask install test requires the GitHub release to be published, because Homebrew cannot download assets from a draft release.

## Remaining manual gates

These should remain explicit human-controlled gates:

- Apple Developer certificate creation/import.
- Notary credential creation.
- Publishing the GitHub release.
- Pushing the Homebrew cask tap.
- Editing real `/etc/pam.d/sudo` during end-to-end validation.
