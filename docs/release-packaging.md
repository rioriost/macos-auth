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

The current Linux packaging scope is Debian/Ubuntu and Fedora/RHEL-family packages on native target builders.

| Distro family | Package manager | x86_64 | arm64/aarch64 |
|---|---|---:|---:|
| Debian / Ubuntu | `apt` / `dpkg` | `.deb` `amd64` | `.deb` `arm64` |
| Fedora / RHEL | `dnf` / `rpm` | `.rpm` `x86_64` | `.rpm` `aarch64` |

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

### Parallels Desktop constraint

On Apple Silicon, Parallels Desktop should be treated as arm64/aarch64 Linux only. Do not assume x86_64 Linux VMs can run locally in Parallels.

This means local Parallels builds are ideal for:

- Ubuntu `arm64`
- RHEL-family `aarch64`
- macOS `darwin-arm64`

For Linux `x86_64`, use a native x86_64 builder. Keep the actual host inventory in local-only documentation or SSH config, not in public repository content.

## Cross-compilation feasibility

Cross-compilation can be useful for developer convenience, but it should not be the primary release acceptance path for PAM packages. Runtime validation still requires a target-architecture system.

### Debian / Ubuntu

Cross-building `.deb` packages on arm64 for `amd64` is feasible but adds complexity:

- Rust target: `x86_64-unknown-linux-gnu`
- C cross compiler: `gcc-x86-64-linux-gnu`
- PAM dev package for target architecture: `libpam0g-dev:amd64`
- multiarch setup: `dpkg --add-architecture amd64`

However, runtime validation of PAM still requires an actual `amd64` environment.

Recommendation:

- Build `arm64` `.deb` in Parallels Ubuntu arm64.
- Build `amd64` `.deb` on a native Debian/Ubuntu x86_64 builder.
- Do not rely solely on cross-compile for release acceptance.

### Fedora / RHEL

Cross-building RPMs for `x86_64` on `aarch64` is possible in theory but not the simplest path for PAM modules.

Complications:

- target `pam-devel` availability
- cross GCC setup
- RPM macro differences
- testing still requires target architecture

Recommendation:

- Build `aarch64` RPM in Parallels RHEL-family arm64.
- Build `x86_64` RPM on a native RHEL-family x86_64 builder.

## Recommended release build flow

### Phase 1: native per-arch builders

Use native target builders to reduce cross-toolchain complexity.

| Package | Recommended builder |
|---|---|
| `.deb arm64` | Parallels Ubuntu arm64 |
| `.deb amd64` | Native Debian/Ubuntu x86_64 builder |
| `.rpm aarch64` | Parallels RHEL-family aarch64 |
| `.rpm x86_64` | Native RHEL-family x86_64 builder |
| macOS cask artifact | macOS Apple Silicon |

### Phase 2: limited cross-compile optimization

After native builds are working, consider cross-compiling only where it reduces maintenance:

- Debian `amd64` from arm64 may be acceptable for build artifact generation, but still test on amd64.
- RPM cross-builds should wait until native packaging is stable.

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

For amd64:

```text
x86_64-linux-gnu
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
  version "0.1.0"
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

Suggested artifact names:

```text
macos-auth-linux-amd64.deb
macos-auth-linux-arm64.deb
macos-auth-linux-x86_64.rpm
macos-auth-linux-aarch64.rpm
macos-auth-darwin-arm64.pkg
```

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

- Add Debian packaging skeleton.
- Add RPM spec skeleton.
- Add macOS `.pkg` build plan/script.
