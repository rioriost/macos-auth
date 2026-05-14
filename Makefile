VERSION ?= 0.1.0
RELEASE_TAG ?= v$(VERSION)
RELEASE_REPO ?= rioriost/macos-auth
RELEASE_TITLE ?= macos-auth v$(VERSION) packages
RELEASE_DIR ?= target/package/release
RELEASE_NOTES ?= $(RELEASE_DIR)/RELEASE-NOTES.md
SOURCE_COMMIT ?= $(shell git rev-parse HEAD)
NOTARY_PROFILE ?= macos-auth-notary
MACOS_SIGNED_PKG ?= target/package/macos/macos-auth-$(VERSION)-darwin-arm64-signed.pkg
MACOS_FINAL_PKG ?= target/package/macos/macos-auth-$(VERSION)-darwin-arm64.pkg

.PHONY: all build test check fmt rust-build rust-test pam-build pam-check shell-check package-deb package-rpm package-x86_64-containers package-macos package-macos-signed notarize-macos release-collect release-verify release-notes release-upload-draft release-status clean

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
	sh -n packaging/linux/build-x86_64-containers.sh
	sh -n packaging/linux/smoke-test-package.sh
	if [ -f packaging/macos/build-pkg.sh ]; then sh -n packaging/macos/build-pkg.sh; fi
	if [ -f packaging/macos/notarize-pkg.sh ]; then sh -n packaging/macos/notarize-pkg.sh; fi
	if [ -f packaging/release/collect-artifacts.sh ]; then sh -n packaging/release/collect-artifacts.sh; fi
	if [ -f packaging/release/verify-artifacts.sh ]; then sh -n packaging/release/verify-artifacts.sh; fi
	if [ -f packaging/release/make-notes.sh ]; then sh -n packaging/release/make-notes.sh; fi
	if [ -f packaging/release/upload-draft.sh ]; then sh -n packaging/release/upload-draft.sh; fi

package-deb:
	packaging/linux/build-deb.sh

package-rpm:
	packaging/linux/build-rpm.sh

package-x86_64-containers:
	packaging/linux/build-x86_64-containers.sh

package-macos:
	@if [ ! -x packaging/macos/build-pkg.sh ]; then echo "packaging/macos/build-pkg.sh is not available in this checkout" >&2; exit 1; fi
	packaging/macos/build-pkg.sh --version $(VERSION)

package-macos-signed:
	@test -n "$(CODESIGN_IDENTITY)" || { echo "Set CODESIGN_IDENTITY" >&2; exit 2; }
	@test -n "$(PKG_SIGN_IDENTITY)" || { echo "Set PKG_SIGN_IDENTITY" >&2; exit 2; }
	@if [ ! -x packaging/macos/build-pkg.sh ]; then echo "packaging/macos/build-pkg.sh is not available in this checkout" >&2; exit 1; fi
	packaging/macos/build-pkg.sh --version $(VERSION) --sign-identity "$(CODESIGN_IDENTITY)" --pkg-sign-identity "$(PKG_SIGN_IDENTITY)"

notarize-macos:
	@if [ ! -x packaging/macos/notarize-pkg.sh ]; then echo "packaging/macos/notarize-pkg.sh is not available in this checkout" >&2; exit 1; fi
	packaging/macos/notarize-pkg.sh --pkg "$(MACOS_SIGNED_PKG)" --keychain-profile "$(NOTARY_PROFILE)" --final-pkg "$(MACOS_FINAL_PKG)" --sha256-file target/package/macos/SHA256SUMS.cask

release-collect:
	@test -n "$(RELEASE_ARTIFACT_SOURCES)" || { echo "Set RELEASE_ARTIFACT_SOURCES to local/remote artifact directories" >&2; exit 2; }
	@if [ ! -x packaging/release/collect-artifacts.sh ]; then echo "packaging/release/collect-artifacts.sh is not available in this checkout" >&2; exit 1; fi
	RELEASE_ARTIFACT_SOURCES="$(RELEASE_ARTIFACT_SOURCES)" packaging/release/collect-artifacts.sh --out-dir "$(RELEASE_DIR)" --version "$(VERSION)" --clean

release-verify:
	@if [ ! -x packaging/release/verify-artifacts.sh ]; then echo "packaging/release/verify-artifacts.sh is not available in this checkout" >&2; exit 1; fi
	packaging/release/verify-artifacts.sh --artifact-dir "$(RELEASE_DIR)" --version "$(VERSION)" --require-macos

release-notes:
	@if [ ! -x packaging/release/make-notes.sh ]; then echo "packaging/release/make-notes.sh is not available in this checkout" >&2; exit 1; fi
	VERSION=$(VERSION) SOURCE_COMMIT=$(SOURCE_COMMIT) OUT_FILE="$(RELEASE_NOTES)" packaging/release/make-notes.sh

release-upload-draft:
	@if [ ! -f "$(RELEASE_NOTES)" ]; then echo "Release notes not found: $(RELEASE_NOTES). Run make release-notes and edit/check validation before upload." >&2; exit 1; fi
	@if [ ! -x packaging/release/upload-draft.sh ]; then echo "packaging/release/upload-draft.sh is not available in this checkout" >&2; exit 1; fi
	packaging/release/upload-draft.sh --repo "$(RELEASE_REPO)" --tag "$(RELEASE_TAG)" --target "$(SOURCE_COMMIT)" --title "$(RELEASE_TITLE)" --notes-file "$(RELEASE_NOTES)" --artifact-dir "$(RELEASE_DIR)"

release-status:
	gh release view "$(RELEASE_TAG)" --repo "$(RELEASE_REPO)"

clean:
	cargo clean
	$(MAKE) -C pam clean
	rm -rf target/package
