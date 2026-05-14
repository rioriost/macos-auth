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
