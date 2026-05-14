#!/bin/sh
set -eu

cargo fmt --all -- --check
cargo test
swift build --package-path agent
agent/.build/debug/macos-auth-agent verify-vector --path test-vectors/v1/approval.json
make -C pam check
sh -n scripts/install-launchagent.sh
sh -n scripts/macos-dev-setup.sh
sh -n scripts/linux-dev-setup.sh
sh -n scripts/linux-install-dev.sh
sh -n scripts/uninstall-launchagent.sh
sh -n scripts/status-launchagent.sh
