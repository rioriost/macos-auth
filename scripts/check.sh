#!/bin/sh
set -eu

cargo fmt --all -- --check
cargo test --locked
make -C pam check
sh -n scripts/check.sh
sh -n scripts/linux-dev-setup.sh
sh -n scripts/linux-install-dev.sh
sh -n packaging/linux/build-deb.sh
sh -n packaging/linux/build-rpm.sh
sh -n packaging/linux/build-x86_64-containers.sh
sh -n packaging/linux/smoke-test-package.sh
if [ -f packaging/macos/build-pkg.sh ]; then sh -n packaging/macos/build-pkg.sh; fi
if [ -f packaging/macos/notarize-pkg.sh ]; then sh -n packaging/macos/notarize-pkg.sh; fi
if [ -f packaging/release/collect-artifacts.sh ]; then sh -n packaging/release/collect-artifacts.sh; fi
if [ -f packaging/release/verify-artifacts.sh ]; then sh -n packaging/release/verify-artifacts.sh; fi
if [ -f packaging/release/make-notes.sh ]; then sh -n packaging/release/make-notes.sh; fi
if [ -f packaging/release/upload-draft.sh ]; then sh -n packaging/release/upload-draft.sh; fi
