#!/bin/sh
set -eu

version=${VERSION:-0.1.0}
source_commit=${SOURCE_COMMIT:-$(git rev-parse HEAD)}
out_file=${OUT_FILE:-target/package/release/RELEASE-NOTES.md}

mkdir -p "$(dirname -- "$out_file")"

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
EOF

echo "wrote $out_file"
