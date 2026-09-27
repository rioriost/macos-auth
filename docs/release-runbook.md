# Release runbook

Current release preparation targets **0.1.2**. Published releases, including
0.1.1, are immutable: do not replace their assets or repoint their tags.

## Prerequisites and release source

- Commit the complete release source and matching Cargo package versions before
  building. All five artifacts must come from that exact full commit SHA.
- Builders and the collector require Git, tar, and Python 3.9+ (standard library
  only). The collector must have the source commit locally to verify its version,
  Git tree, and archive digest; its own HEAD may differ and is recorded separately.
- Native Ubuntu 24.04 and 25.10 builders require Rust/Cargo, make, C compiler,
  PAM development headers, and dpkg/dpkg-deb/dpkg-architecture.
- Native RHEL 9/10-family builders require Rust/Cargo, make, GCC, PAM development
  headers, rpm, and rpmbuild. These scripts do not support Fedora release artifacts.
- All build targets are arm64/aarch64 only. An arm64/aarch64 host with Podman and
  an arm64 Linux runtime can build the four Linux targets in Ubuntu and UBI
  containers; this does not replace native PAM acceptance. The container wrapper
  also requires `sha256sum` (GNU coreutils).
- Apple Silicon macOS requires the committed `agent/` and LaunchAgent sources,
  Swift/Xcode command-line tools, `pkgbuild`, `productbuild`, `codesign`,
  `pkgutil`, `spctl`, and `xcrun` with `notarytool`/`stapler`. Distribution also
  requires Developer ID Application and Installer identities plus a configured
  notary Keychain profile.
- Upload requires an authenticated `gh` with permission to manage releases.
  Homebrew cask maintenance is in the separate `../homebrew-cask/` repository.

Keep private hostnames, credentials, and signing identity details in ignored local
inventory (`docs/build-farm.local.md`) or local SSH/Keychain configuration. A tool
being installed does not prove builder connectivity, signing access, or validation.

```sh
VERSION=0.1.2
SOURCE_COMMIT=$(git rev-parse HEAD)
```

Check out this same commit on every builder. Release builds reject staged,
unstaged, and non-ignored untracked files. They compile a fresh committed archive
in isolated staging; ignored stale build outputs are never packaged.

## Linux package builds

On each Ubuntu target:

```sh
make check
VERSION=0.1.2 packaging/linux/build-deb.sh
```

On each RHEL-family target:

```sh
make check
VERSION=0.1.2 packaging/linux/build-rpm.sh
```

On the arm64/aarch64 Podman builder:

```sh
VERSION=0.1.2 SOURCE_REF="$SOURCE_COMMIT" packaging/linux/build-arm64-containers.sh
```

OS and architecture are detected on the builder. Both native and container paths
produce identical canonical names:

```text
macos-auth_0.1.2_ubuntu24.04_arm64.deb
macos-auth_0.1.2_ubuntu25.10_arm64.deb
macos-auth-0.1.2-1.rhel9.aarch64.rpm
macos-auth-0.1.2-1.rhel10.aarch64.rpm
```

Each artifact has `<artifact>.metadata.json` and `<artifact>.sha256` sidecars.
Copy these with the package; never rename packages or manufacture metadata on the
collector. RPM's internal release is also `1.rhel9`/`1.rhel10`, not `1.elN`.
Choose a fresh ignored output directory with `OUT_DIR` for rebuilds; existing
artifact names are not silently overwritten.

## macOS build and notarization

Use a separate output directory for unsigned local experiments:

```sh
packaging/macos/build-pkg.sh --development --out-dir target/package/macos-dev
```

Development snapshots record their exact input digest but are explicitly
non-release, even if the worktree happens to be clean. `--skip-build` is rejected:
an arbitrary previously built binary cannot prove its source.

Build from the committed release source:

```sh
make package-macos-signed VERSION=0.1.2 \
  CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
  PKG_SIGN_IDENTITY="Developer ID Installer: YOUR NAME (TEAMID)"
make notarize-macos VERSION=0.1.2 NOTARY_PROFILE=macos-auth-notary
```

`notarize-pkg.sh` validates the signed input's sidecars, operates on an isolated
copy, verifies the stapled ticket/signature/Gatekeeper assessment, and writes:

```text
target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg
target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg.metadata.json
target/package/macos/macos-auth-0.1.2-darwin-arm64.pkg.sha256
target/package/macos/SHA256SUMS.cask
```

The signed intermediate and its provenance remain unchanged. Final metadata links
back to that input and hashes the **final stapled bytes**. Do not manually staple,
rename, or copy over a recorded artifact. Existing final outputs cause an error.
The build script never recursively removes a caller-selected output directory.

## Assemble and verify

Use local directories and/or scp-compatible remote builder directories:

```sh
packaging/release/collect-artifacts.sh \
  --version 0.1.2 --source-commit "$SOURCE_COMMIT" \
  --out-dir target/package/release --clean \
  --source target/package/arm64-containers \
  --source target/package/macos
packaging/release/verify-artifacts.sh \
  --version 0.1.2 --source-commit "$SOURCE_COMMIT" \
  --artifact-dir target/package/release --require-macos
```

Alternatively use `make release-collect` with `RELEASE_ARTIFACT_SOURCES` and
`SOURCE_COMMIT`, then `make release-verify`. Environment source lists split on
whitespace; use repeated `--source` arguments for paths containing spaces.

Collection preserves the original per-artifact sidecar bytes. It rejects missing
metadata/checksums, changed bytes, wrong source revisions/trees/archives, mismatched
versions, development/unsigned artifacts, unsupported architectures, and
conflicting duplicate names.
Identical duplicates are allowed; distinct builder records are conflicts even
when the package hashes happen to agree. Remote retrieval errors are fatal.
`--clean` removes only known release outputs, retaining unrelated files and edited
release notes, and never recursively deletes the output directory.

`BUILD-METADATA.txt` and `BUILD-METADATA-darwin-arm64.txt` contain schema-v1 JSON
collection indexes. They distinguish `source.source_commit` from
`collector.revision`/`collector.dirty` and pin every builder sidecar by SHA256.
`SHA256SUMS` covers all Linux packages; `SHA256SUMS-darwin-arm64` covers macOS.
Verification requires **all four arm64/aarch64 Linux packages**, and the normal
release target additionally requires notarized macOS. On macOS it also reruns
stapler, signature, and Gatekeeper checks. Hash/provenance checks are not package
install or PAM tests.

These records are integrity/provenance manifests from trusted builders, not
cryptographically signed attestations. Protect builder access and the transport.
Old artifacts without provenance must be rebuilt; do not backfill their origin.

### Explicit source + macOS-only release

If Linux builders are unavailable, a release owner may explicitly choose a
source + macOS-only release, as with the published 0.1.1 macOS-only rebuild.
This is **not** an automatic fallback or a successful full-matrix release.
The normal `make release-verify` and draft-upload defaults still require all four
Linux packages plus notarized macOS.

Build/sign/notarize the macOS package from the clean committed release source as
above. Use a distinct staging directory and run the strict selection **on macOS**:

```sh
packaging/release/collect-artifacts.sh \
  --version 0.1.2 --source-commit "$SOURCE_COMMIT" \
  --out-dir target/package/release-macos --clean --macos-only \
  --source target/package/macos
packaging/release/verify-artifacts.sh \
  --version 0.1.2 --source-commit "$SOURCE_COMMIT" \
  --artifact-dir target/package/release-macos --macos-only
```

`--macos-only` requires the canonical notarized package, original builder metadata
and checksums, expected source revision/version/tree/archive, final-byte hashes,
and matching collection indexes. It rejects Linux packages in this directory.
It also requires successful stapler, package signature, and Gatekeeper checks;
non-macOS hosts fail rather than silently skipping those checks.

Generate explicitly scoped notes, then edit them with actual test evidence and
all limitations:

```sh
VERSION=0.1.2 SOURCE_COMMIT="$SOURCE_COMMIT" RELEASE_SCOPE=macos-only \
  OUT_FILE=target/package/release-macos/RELEASE-NOTES.md \
  packaging/release/make-notes.sh
packaging/release/upload-draft.sh --macos-only \
  --repo rioriost/macos-auth --tag v0.1.2 --target "$SOURCE_COMMIT" \
  --title "macos-auth v0.1.2 — source + macOS only" \
  --notes-file target/package/release-macos/RELEASE-NOTES.md \
  --artifact-dir target/package/release-macos
```

Draft upload reruns this strict limited-scope gate only when `--macos-only` is
explicit. Published-release protection is identical in both modes. GitHub's source
archives come from the tag; they do not imply that any Linux packages were built
or validated. Publishing remains a separate deliberate action.

## Release notes and draft upload

```sh
make release-notes VERSION=0.1.2 SOURCE_COMMIT="$SOURCE_COMMIT"
# Edit target/package/release/RELEASE-NOTES.md with actual validation evidence.
make release-upload-draft VERSION=0.1.2 RELEASE_TAG=v0.1.2 \
  SOURCE_COMMIT="$SOURCE_COMMIT" RELEASE_REPO=rioriost/macos-auth
```

By default, upload independently runs the full five-package verification gate.
It queries `isDraft` before any mutation and refuses published releases. A failed query is not
interpreted as absence: creation requires a successful complete release listing
that confirms the tag is missing. Auth, network, and ambiguous query failures stop
the upload. Existing draft assets may be replaced with `--clobber`.

Do not publish concurrently with an upload: the script rechecks immediately before
mutations, but GitHub does not provide an atomic draft-state precondition. Publishing
is an explicit separate human-controlled action; this script never publishes.

## Validation and remaining manual gates

Offline regression tests (no network, package installation, or Apple operations):

```sh
python3 -B -m unittest discover -s packaging/release/tests -v
make shell-check
```

The tests use synthetic bytes and mocked GitHub/Apple commands; they do **not**
establish real package, signing, notarization, or PAM acceptance.

Before promotion, record `make check` on supported builders, install/uninstall and
PAM smoke results for all Linux targets, and actual macOS install/LaunchAgent/SSH
end-to-end results. Run `pamtester` before any deliberate sudo PAM edits and keep
a root shell open. Certificate setup, notary credentials, publication, and pushing
the cask tap remain explicit manual gates.

After actual notarization, update the separate cask to 0.1.2 using the final hash
in `SHA256SUMS.cask`, then run `brew style --cask` and `brew audit --cask`.
Homebrew download/install testing requires a published release, not a draft.
