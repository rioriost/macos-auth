.PHONY: all build test check fmt rust-test swift-build swift-vector pam-check shell-check clean

all: check

build: swift-build
	cargo build
	$(MAKE) -C pam

check: fmt rust-test swift-build swift-vector pam-check shell-check

fmt:
	cargo fmt --all -- --check

rust-test:
	cargo test

swift-build:
	swift build --package-path agent

swift-vector: swift-build
	agent/.build/debug/macos-auth-agent verify-vector --path test-vectors/v1/approval.json

pam-check:
	$(MAKE) -C pam check

shell-check:
	sh -n scripts/install-launchagent.sh
	sh -n scripts/macos-dev-setup.sh
	sh -n scripts/linux-dev-setup.sh
	sh -n scripts/linux-install-dev.sh
	sh -n scripts/uninstall-launchagent.sh
	sh -n scripts/status-launchagent.sh

clean:
	cargo clean
	swift package --package-path agent clean
	$(MAKE) -C pam clean
