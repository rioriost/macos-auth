# Build farm

This document describes the sanitized, public-safe build-farm policy for native Linux and macOS package builds.

Keep concrete hostnames, LAN IP addresses, usernames, SSH details, signing keys, and credentials out of public repository content. Store local inventory in `docs/build-farm.local.md` or in `~/.ssh/config`; `docs/build-farm.local.md` is ignored by git.

## Goals

- Prefer native target builders over cross-compilation for release acceptance.
- Validate PAM behavior on the same distro family and architecture as the package artifact.
- Keep `make check` as the local quality gate before packaging and before commits.
- Keep public repository content limited to build/packaging code, configuration, and sanitized documentation.

## Current builder roles

| Role | Architecture | Intended use |
|---|---:|---|
| Ubuntu LTS arm64 builder | `aarch64` / `arm64` | Build and validate `.deb arm64` packages |
| Ubuntu current arm64 builder | `aarch64` / `arm64` | Forward-looking `.deb arm64` validation |
| RHEL 9 arm64 builder | `aarch64` | Build and validate `.rpm aarch64` packages for RHEL 9-family systems |
| RHEL 10 arm64 builder | `aarch64` | Forward-looking `.rpm aarch64` validation |
| Native Linux x86_64 builder | `x86_64` | Build and validate x86_64 artifacts on native hardware |
| macOS Apple Silicon builder | `arm64` | Build signed/notarized macOS artifacts |

Arch Linux is not part of the current build-farm plan.

## Local inventory template

Create `docs/build-farm.local.md` locally if you want to record concrete SSH targets. Do not commit it.

```text
# Local build farm inventory

| Alias | Distro/version | Architecture | SSH target | Notes |
|---|---|---:|---|---|
| macos-auth-ubuntu-lts-arm64 | Ubuntu LTS | arm64 | user@host | Parallels VM |
| macos-auth-ubuntu-current-arm64 | Ubuntu current | arm64 | user@host | Parallels VM |
| macos-auth-rhel9-arm64 | RHEL 9 | aarch64 | user@host | Parallels VM |
| macos-auth-rhel10-arm64 | RHEL 10 | aarch64 | user@host | Parallels VM |
| macos-auth-linux-x86_64 | Linux | x86_64 | user@host | Native builder |
```

Recommended `~/.ssh/config` style:

```text
Host macos-auth-ubuntu-lts-arm64
    HostName <private-host-or-ip>
    User <builder-user>

Host macos-auth-rhel9-arm64
    HostName <private-host-or-ip>
    User <builder-user>
```

## Baseline checks per builder

Run these after provisioning and after major OS upgrades:

```text
hostnamectl
uname -m
id
ssh -V
make --version
```

Then install build dependencies for the relevant distro family and run:

```text
make check
```

If a builder is package-only and cannot run the full macOS/Swift checks, record that limitation in the local inventory and run the full quality gate on macOS before promotion.

## Package build matrix

| Artifact | Primary builder role | Required validation |
|---|---|---|
| `.deb arm64` | Ubuntu LTS arm64 builder | Install, helper direct test, `pamtester`, `sudo`, rollback |
| `.deb amd64` | Native Debian/Ubuntu x86_64 builder | Install, helper direct test, `pamtester`, `sudo`, rollback |
| `.rpm aarch64` | RHEL 9 arm64 builder | Install, helper direct test, `pamtester`, `sudo`, rollback |
| `.rpm x86_64` | Native RHEL-family x86_64 builder | Install, helper direct test, `pamtester`, `sudo`, rollback |
| `darwin-arm64.pkg` | macOS Apple Silicon builder | Install, LaunchAgent load/status/unload, manual `serve`, SSH RemoteForward |

## Promotion rules

A release artifact can be promoted only after:

1. `make check` passes on macOS.
2. The package builds on the native target builder.
3. The package is installed from the generated artifact, not from the build tree.
4. `pamtester` passes before any `sudo` PAM edits.
5. Fallback and hard-fail cases are manually verified.
6. Rollback is verified.
7. Artifact checksums are recorded.

## Public-scope checklist

Before pushing build-farm or packaging changes to the public repository, verify:

- no LAN IP addresses or private hostnames are included
- no usernames, SSH config, private keys, signing material, tokens, or generated configs are included
- no VM snapshots or generated artifacts are included
- docs reference roles/aliases instead of concrete infrastructure details
- build scripts fail closed when required secrets or signing identities are missing
