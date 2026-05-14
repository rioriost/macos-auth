# Linux packaging

Linux release packaging currently targets Debian/Ubuntu and Fedora/RHEL-family packages built on native target builders.

| Package | Architecture |
|---|---:|
| `.deb` | `amd64` |
| `.deb` | `arm64` |
| `.rpm` | `x86_64` |
| `.rpm` | `aarch64` |

Arch packaging is deferred.

See `docs/release-packaging.md` for the full plan.

## Contents

Linux packages should contain:

- `macos-auth-helper`
- `pam_macos_auth.so`
- documentation and examples
- `/usr/share/macos-auth/examples/config.toml.sample`
- `/usr/share/macos-auth/examples/ssh-config.sample`

Linux packages must not automatically modify `/etc/pam.d/sudo`.

## Build

On Debian/Ubuntu builders:

```text
packaging/linux/build-deb.sh
```

On Fedora/RHEL-family builders:

```text
packaging/linux/build-rpm.sh
```

Both scripts build from the local source tree and write artifacts under `target/package/`.

## x86_64 containerized build

On an x86_64 host with Podman, build all current x86_64 Linux package targets in clean containers:

```text
packaging/linux/build-x86_64-containers.sh
```

This builds:

- Ubuntu 24.04 `amd64` `.deb`
- Ubuntu 25.10 `amd64` `.deb`
- RHEL 9-family `x86_64` `.rpm` using UBI 9.7
- RHEL 10-family `x86_64` `.rpm` using UBI 10.1

Artifacts, `SHA256SUMS`, and `BUILD-METADATA.txt` are written to `target/package/x86_64-containers/`.

The script packages tracked files from the current git ref, `HEAD` by default. Set `SOURCE_REF` to build another ref.

## Install/uninstall smoke test

In a disposable VM or test container, run the package smoke test as root:

```text
sudo packaging/linux/smoke-test-package.sh target/package/deb/macos-auth_0.1.0_arm64.deb
sudo packaging/linux/smoke-test-package.sh target/package/rpm/macos-auth-0.1.0-1.el9.aarch64.rpm
```

The smoke test installs the package, runs `/usr/bin/macos-auth-helper --help`, lists installed package files, and uninstalls the package. It does not modify `/etc/pam.d/sudo` and does not run `pamtester`.
