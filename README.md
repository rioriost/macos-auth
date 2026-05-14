# macos-auth Linux packaging subset

`macos-auth` is an experimental PAM module plus helper for approving Linux authentication requests through a macOS user-session agent.

This public repository currently contains the Linux build and packaging subset needed to build Debian/Ubuntu `.deb` packages and Fedora/RHEL-family `.rpm` packages:

- Rust protocol and Linux helper crates
- C PAM shim
- Linux package build scripts and package metadata
- Linux testing and packaging documentation

The macOS agent implementation and local build-farm inventory are intentionally not published here.

> **Status:** development-only. Do not use this as a production authentication mechanism yet.

## Components in this repository

| Component | Path | Purpose |
|---|---|---|
| Protocol crate | `crates/protocol` | Signed request/response types, canonical bytes, signature verification |
| Linux helper | `crates/helper` | Generates signed PAM requests, talks to agent socket, verifies responses |
| PAM shim | `pam/pam_macos_auth.c` | Extracts PAM context, invokes helper, maps helper exit codes to PAM results |
| Debian packaging | `packaging/linux/build-deb.sh`, `packaging/linux/deb/` | Native `.deb` package build |
| RPM packaging | `packaging/linux/build-rpm.sh`, `packaging/linux/rpm/` | Native `.rpm` package build |
| Linux setup helpers | `scripts/linux-*.sh` | Development config/install helpers for VM testing |

## Build prerequisites

Debian/Ubuntu builders:

```text
sudo apt-get update
sudo apt-get install -y build-essential cargo dpkg-dev libpam0g-dev make rustc
```

Fedora/RHEL-family builders:

```text
sudo dnf install -y cargo gcc make pam-devel rpm-build rust
```

Using a current Rust toolchain through `rustup` is also acceptable on local builders.

## Quality gate

Run before packaging or committing:

```text
make check
```

This runs:

- Rust formatting check
- Rust tests
- PAM C syntax check
- shell script syntax checks

Equivalent:

```text
scripts/check.sh
```

## Build Linux packages

### Debian/Ubuntu `.deb`

Run on a native Debian/Ubuntu builder:

```text
make package-deb
```

Equivalent:

```text
packaging/linux/build-deb.sh
```

The artifact is written under `target/package/deb/`.

### Fedora/RHEL `.rpm`

Run on a native Fedora/RHEL-family builder:

```text
make package-rpm
```

Equivalent:

```text
packaging/linux/build-rpm.sh
```

The artifact is written under `target/package/rpm/`.

If Rust is installed through `rustup` rather than distro RPM packages, `rpmbuild` dependency checks may not see it. In that case, install the distro `rust` / `cargo` packages or run with explicit local-builder options, for example:

```text
RPMBUILD_OPTS=--nodeps packaging/linux/build-rpm.sh
```

## Package contents

Linux packages install:

- `/usr/bin/macos-auth-helper`
- `pam_macos_auth.so` in the distro PAM module directory
- package documentation under `/usr/share/doc/macos-auth/`
- PAM examples under `/usr/share/macos-auth/examples/`

Packages must not automatically modify `/etc/pam.d/sudo`.

## PAM testing

Do **not** edit `/etc/pam.d/sudo` first.

Use the test service and `pamtester` flow in:

- `docs/pam-testing.md`
- `pam/examples/macos-auth-test`

Recommended PAM control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper
```

This means:

- macOS approval succeeds immediately
- authenticator unavailable/cancel/failure falls back to password
- tampering/unsafe config/protocol errors hard fail

## Documentation index

| Document | Purpose |
|---|---|
| `docs/release-packaging.md` | Release packaging plan for Linux and macOS artifacts |
| `docs/build-farm.md` | Local/native build farm policy and builder roles |
| `docs/linux-vm-test-plan.md` | Manual Parallels VM test plan for Ubuntu/Debian and Fedora/RHEL |
| `docs/pam-testing.md` | PAM testing guide |
| `docs/helper.md` | Linux helper usage |
| `pam/README.md` | PAM shim usage |
| `packaging/linux/README.md` | Linux package build notes |

## License

MIT. See `LICENSE`.
