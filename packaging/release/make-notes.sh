#!/bin/sh
set -eu

version=${VERSION:-0.1.2}
source_commit=${SOURCE_COMMIT:-$(git rev-parse HEAD)}
out_file=${OUT_FILE:-target/package/release/RELEASE-NOTES.md}
release_scope=${RELEASE_SCOPE:-full}

mkdir -p "$(dirname -- "$out_file")"

case "$release_scope" in
  full) ;;
  macos-only)
    cat > "$out_file" <<EOF
# macos-auth v$version — source + macOS only

This release contains the source at \`$source_commit\` and a signed, notarized
Apple Silicon macOS agent package. **No Linux binary packages are included.**
Linux package builds and the full eight-target Linux release gate have not been
completed for this release. This is an explicit limited-scope release, not a
successful full package release.

Status: development-only. Do not use this as a production authentication mechanism yet.

## Artifact

- \`macos-auth-${version}-darwin-arm64.pkg\`
- Matching \`.metadata.json\` and \`.sha256\` builder-provenance sidecars.
- \`SHA256SUMS-darwin-arm64\` and collection metadata.
- GitHub's source archives are generated from the release tag.

## Validation checklist

- [ ] Source tests passed; list actual commands and results.
- [ ] Package signature, notarization, stapled ticket, and Gatekeeper checks passed.
- [ ] Strict \`verify-artifacts.sh --macos-only\` provenance/hash/signature gate passed.
- [ ] macOS install, LaunchAgent, and SSH end-to-end validation completed; describe limitations.
- [ ] Homebrew cask style/audit passed, or explicitly document what was not run.

The standard full release gate remains unchanged. Do not claim Linux package,
PAM, or native-builder acceptance based on this macOS-only release.
EOF
    echo "wrote explicit macOS-only notes: $out_file"
    exit 0
    ;;
  *)
    echo "RELEASE_SCOPE must be full or macos-only" >&2
    exit 2
    ;;
esac

cat > "$out_file" <<EOF
# macos-auth v$version package draft

This draft release contains Linux packages and a signed/notarized macOS agent package.

Status: development-only. Do not use this as a production authentication mechanism yet.

Source commit: \`$source_commit\`

## Artifacts

### Debian / Ubuntu

- \`macos-auth_${version}_ubuntu24.04_amd64.deb\`
- \`macos-auth_${version}_ubuntu24.04_arm64.deb\`
- \`macos-auth_${version}_ubuntu25.10_amd64.deb\`
- \`macos-auth_${version}_ubuntu25.10_arm64.deb\`

### RHEL-family

- \`macos-auth-${version}-1.rhel9.x86_64.rpm\`
- \`macos-auth-${version}-1.rhel9.aarch64.rpm\`
- \`macos-auth-${version}-1.rhel10.x86_64.rpm\`
- \`macos-auth-${version}-1.rhel10.aarch64.rpm\`

### macOS

- \`macos-auth-${version}-darwin-arm64.pkg\`

## Validation checklist

- [ ] \`make check\` passed on supported native Linux builders.
- [ ] x86_64 packages built in clean Podman containers.
- [ ] Install/uninstall smoke tests passed for all Linux artifacts.
- [ ] PAM integration smoke tests passed for all Linux artifacts.
- [ ] Manual macOS agent end-to-end smoke passed over SSH \`RemoteForward\`.
- [ ] macOS package signed, notarized, stapled, and accepted by \`spctl\`.
- [ ] Homebrew cask style/audit passed.

## Safety notes

- Packages do not modify \`/etc/pam.d/sudo\` automatically.
- Test with \`pamtester\` before changing any real PAM service.
- Keep a root shell open before editing sudo PAM configuration.
- The macOS package installs the agent under \`/opt/homebrew\`, but does not automatically create user keys, host allowlists, or LaunchAgent state.

See \`SHA256SUMS\` and \`SHA256SUMS-darwin-arm64\` for artifact checksums.
Each package includes its builder-supplied \`.metadata.json\` and \`.sha256\` sidecars.
Collection verifies the committed source revision/version and preserves these sidecars.
EOF

echo "wrote $out_file"
