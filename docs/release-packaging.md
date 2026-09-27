# Release packaging plan

This document describes the intended binary/package distribution model and the current native-builder release strategy.

The release process is intentionally based on local/native builders and manual promotion. Public repository contents should stay limited to build and packaging code, build configuration, and non-sensitive build documentation.

## Public repository scope

The public repository for build and packaging work is:

```text
https://github.com/rioriost/macos-auth
```

Do not publish more than is needed for build and packaging automation.

Public-safe examples:

- package build scripts and package metadata
- local quality-gate scripts
- release packaging documentation
- sanitized build-farm documentation
- artifact naming and validation checklists

Keep these out of git:

- private keys, signing keys, certificates, provisioning profiles, and tokens
- local host inventories with LAN IP addresses, usernames, or SSH details
- generated configs that contain host keys or environment-specific paths
- unreleased implementation notes not needed for build or packaging

If local builder inventory is useful, keep it in `docs/build-farm.local.md`, which is ignored by git.

## Supported release targets

### Linux

The current release matrix is Ubuntu 24.04/25.10 and RHEL 9/10-family packages on
native arm64/aarch64 builders (not arbitrary Debian or Fedora releases).
Other architectures, including x86_64/amd64, are not supported for source builds
or release packages.

| Distro family | Package manager | Architecture |
|---|---|---|
| Ubuntu 24.04 / 25.10 | `apt` / `dpkg` | `.deb` `arm64` |
| RHEL 9 / 10 family | `dnf` / `rpm` | `.rpm` `aarch64` |

Arch packaging is deferred and is not part of the current release plan.

Linux packages contain:

- `macos-auth-helper`
- `pam_macos_auth.so`
- example configs/docs
- no automatic modification of `/etc/pam.d/sudo`

The Linux packages should install a test PAM service only if explicitly requested by post-install instructions. They should not silently alter sudo authentication.

### macOS

macOS support is Apple Silicon only.

Intended distribution:

- Homebrew cask
- artifact: signed/notarized Apple Silicon package or app bundle
- contains `macos-auth-agent`, LaunchAgent template, and helper scripts

macOS package does not include Linux PAM components.

## Architecture notes

Use arm64/aarch64 Linux guests in Parallels Desktop on Apple Silicon, or native
arm64 Linux hardware. Rust calls this architecture `aarch64`; Swift, macOS, and
Debian packages call it `arm64`; RPM uses `aarch64`.

Rust, Swift, and PAM sources reject compilation for other architectures.
Linux package builders reject non-arm64 hosts, and release naming, collection,
and verification reject non-arm64 artifacts, including older x86_64 packages.
RPM additionally declares `ExclusiveArch: aarch64`.

Keep the actual host inventory in local-only documentation or SSH config, not in
public repository content. Cross-compilation is not a release acceptance path;
PAM runtime validation requires the target distro on arm64/aarch64.

## Recommended release build flow

Use native arm64/aarch64 builders to reduce cross-toolchain complexity.

| Package | Recommended builder |
|---|---|
| `.deb arm64` | Parallels Ubuntu arm64 |
| `.rpm aarch64` | Parallels RHEL-family aarch64 |
| macOS cask artifact | macOS Apple Silicon |

Alternatively, `make package-arm64-containers` builds the four Linux targets in
Podman containers pinned to `linux/arm64`. Container builds do not replace native
install, PAM, and rollback validation.

## Linux package install paths

### Debian / Ubuntu

Suggested paths:

```text
/usr/bin/macos-auth-helper
/usr/lib/<multiarch>/security/pam_macos_auth.so
/usr/share/doc/macos-auth/
/usr/share/macos-auth/examples/
```

For arm64, `<multiarch>` is usually:

```text
aarch64-linux-gnu
```

### Fedora / RHEL

Suggested paths:

```text
/usr/bin/macos-auth-helper
%{_libdir}/security/pam_macos_auth.so
%{_docdir}/macos-auth/
%{_datadir}/macos-auth/examples/
```

## Package safety rules

Linux packages must not:

- modify `/etc/pam.d/sudo` automatically
- enable passwordless sudo
- generate trusted keys silently without user action
- install configs with permissive private key permissions

Linux packages may:

- install binaries/modules
- install example PAM service files under documentation or examples
- print post-install instructions
- provide a separate setup command/script

## macOS Homebrew cask plan

Because the intended distribution is Homebrew cask, the macOS artifact should be one of:

1. signed and notarized `.pkg`
2. signed `.app` wrapper with embedded CLI/agent resources
3. signed tar/zip accepted by cask, though `.pkg` is cleaner for LaunchAgent-related installation

Initial cask concept:

```ruby
cask "macos-auth" do
  version "0.1.2"
  sha256 "..."

  url "https://github.com/rioriost/macos-auth/releases/download/v#{version}/macos-auth-#{version}-darwin-arm64.pkg"
  name "macos-auth"
  desc "macOS agent for approving Linux PAM authentication with Apple Watch or Touch ID"
  homepage "https://github.com/rioriost/macos-auth"

  depends_on arch: :arm64

  pkg "macos-auth-#{version}-darwin-arm64.pkg"

  uninstall launchctl: "com.macos-auth.agent",
            pkgutil: "com.macos-auth.pkg"
end
```

Open question:

- A Homebrew formula may be more natural for a CLI/agent without an `.app`, but the current target is cask. A `.pkg` artifact makes cask distribution more appropriate.

## Release artifact naming

Required current release artifact names:

```text
macos-auth_0.1.2_ubuntu24.04_arm64.deb
macos-auth_0.1.2_ubuntu25.10_arm64.deb
macos-auth-0.1.2-1.rhel9.aarch64.rpm
macos-auth-0.1.2-1.rhel10.aarch64.rpm
macos-auth-0.1.2-darwin-arm64.pkg
SHA256SUMS
SHA256SUMS-darwin-arm64
BUILD-METADATA.txt
BUILD-METADATA-darwin-arm64.txt
```

Each package additionally requires its builder-supplied `.metadata.json` and
`.sha256` sidecars. Native and container builders use the same naming rules.
Release builds use a clean committed snapshot; collection verifies its expected
revision/version and package hashes without inventing provenance from collector
HEAD. See [the release runbook](release-runbook.md) for schema and exact commands.

## Validation before release

Each Linux package must be validated with:

- install package
- verify file paths and permissions
- run helper direct test
- run `pamtester` service test
- run `sudo` test only after `pamtester`
- rollback test

macOS cask artifact must be validated with:

- install
- agent key setup
- LaunchAgent load/status/unload
- manual `serve` test
- SSH RemoteForward test with at least one Linux VM

## Next packaging tasks

- Validate `packaging/linux/build-deb.sh` on Ubuntu 24.04 and 25.10 arm64 builders.
- Validate `packaging/linux/build-rpm.sh` on RHEL 9/10-family aarch64 builders.
- Complete actual signing/notarization and install checks on the macOS builder.
- Preserve builder provenance and record real acceptance results before promotion;
  offline packaging tests alone are not release acceptance.
