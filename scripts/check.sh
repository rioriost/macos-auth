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
