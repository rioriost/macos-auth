# Linux packaging

Linux release packaging targets Ubuntu 24.04/25.10 and RHEL 9/10-family packages built on native target builders.

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

On Ubuntu builders:

```text
packaging/linux/build-deb.sh
```

On RHEL-family builders:

```text
packaging/linux/build-rpm.sh
```

Both scripts require a clean committed source tree, Git, tar, and Python 3.9+
in addition to Rust/Cargo, make, the C/PAM toolchain, and native package tools.
They build a fresh archive of HEAD, not cached worktree binaries, and write under
`target/package/`. `VERSION` must match the committed helper manifest (currently
0.1.2). Existing output artifacts are refused; use a fresh ignored `OUT_DIR`.

The native OS/architecture determines the canonical filename, for example
`macos-auth_0.1.2_ubuntu24.04_arm64.deb` or
`macos-auth-0.1.2-1.rhel9.aarch64.rpm`. RPM internal release tags are also
`1.rhel9`/`1.rhel10`. Do not rename outputs.

Every package has `.metadata.json` and `.sha256` sidecars recording its version,
source commit/tree/archive digest, exact input snapshot, and final package hash.
Keep all three files together when transferring them to the collector.
See [the release runbook](../../docs/release-runbook.md) for collection and gates.

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

Artifacts, their per-artifact sidecars, and `SHA256SUMS` are written to
`target/package/x86_64-containers/`. Names and provenance are produced by the same
native builder scripts, not renamed by the container wrapper.

The script clones the committed git ref, `HEAD` by default, into isolated staging.
Set `SOURCE_REF` to another commit containing these provenance-aware scripts, and
set `VERSION` to that commit's version. The invoking checkout must also be clean.

## Install/uninstall smoke test

In a disposable VM or test container, run the package smoke test as root:

```text
sudo packaging/linux/smoke-test-package.sh target/package/deb/macos-auth_0.1.2_ubuntu24.04_arm64.deb
sudo packaging/linux/smoke-test-package.sh target/package/rpm/macos-auth-0.1.2-1.rhel9.aarch64.rpm
```

The smoke test installs the package, runs `/usr/bin/macos-auth-helper --help`, lists installed package files, and uninstalls the package. It does not modify `/etc/pam.d/sudo` and does not run `pamtester`.
