.PHONY: all build test check fmt rust-build rust-test pam-build pam-check shell-check package-deb package-rpm clean

all: check

build: rust-build pam-build

check: fmt rust-test pam-check shell-check

test: rust-test

fmt:
	cargo fmt --all -- --check

rust-build:
	cargo build --locked

rust-test:
	cargo test --locked

pam-build:
	$(MAKE) -C pam

pam-check:
	$(MAKE) -C pam check

shell-check:
	sh -n scripts/check.sh
	sh -n scripts/linux-dev-setup.sh
	sh -n scripts/linux-install-dev.sh
	sh -n packaging/linux/build-deb.sh
	sh -n packaging/linux/build-rpm.sh

package-deb:
	packaging/linux/build-deb.sh

package-rpm:
	packaging/linux/build-rpm.sh

clean:
	cargo clean
	$(MAKE) -C pam clean
	rm -rf target/package
