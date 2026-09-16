VERSION ?= 0.1.2
PYTHON ?= python3
RELEASE_TAG ?= v$(VERSION)
RELEASE_REPO ?= rioriost/macos-auth
RELEASE_TITLE ?= macos-auth v$(VERSION) packages
RELEASE_DIR ?= target/package/release
RELEASE_NOTES ?= $(RELEASE_DIR)/RELEASE-NOTES.md
RELEASE_SCOPE_FLAGS ?=
SOURCE_COMMIT ?= $(shell git rev-parse HEAD)
NOTARY_PROFILE ?= macos-auth-notary
MACOS_SIGNED_PKG ?= target/package/macos/macos-auth-$(VERSION)-darwin-arm64-signed.pkg
MACOS_FINAL_PKG ?= target/package/macos/macos-auth-$(VERSION)-darwin-arm64.pkg

.PHONY: all build test check fmt rust-build rust-test pam-build pam-check pam-e2e swift-build swift-test python-test shell-check package-deb package-rpm package-x86_64-containers package-macos package-macos-signed notarize-macos release-collect release-verify release-notes release-upload-draft release-status clean

all: check

build: rust-build pam-build swift-build

check: fmt rust-test pam-check swift-test python-test shell-check

test: rust-test pam-check swift-test python-test

fmt:
	cargo fmt --all -- --check

rust-build:
	cargo build --locked

rust-test:
	cargo test --locked

pam-build:
	$(MAKE) -C pam

pam-check:
	$(MAKE) -C pam check test

pam-e2e: rust-build pam-build
	$(PYTHON) tests/pam_e2e.py

swift-build:
	@if [ "$$(uname -s)" = Darwin ]; then swift build --package-path agent; else echo "Swift agent build requires macOS"; fi

swift-test:
	@if [ "$$(uname -s)" = Darwin ]; then \
	  swift test --package-path agent && \
	  agent/.build/debug/macos-auth-agent verify-vector --path test-vectors/v1/approval.json; \
	else echo "Swift agent tests require macOS"; fi

python-test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py'
	$(PYTHON) -B -m unittest discover -s packaging/release/tests -p 'test_*.py'

shell-check:
	@set -e; for script in scripts/*.sh packaging/linux/*.sh packaging/macos/*.sh packaging/release/*.sh; do sh -n "$$script"; done

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
	RELEASE_ARTIFACT_SOURCES="$(RELEASE_ARTIFACT_SOURCES)" packaging/release/collect-artifacts.sh --out-dir "$(RELEASE_DIR)" --version "$(VERSION)" --source-commit "$(SOURCE_COMMIT)" $(RELEASE_SCOPE_FLAGS) --clean

release-verify:
	@if [ ! -x packaging/release/verify-artifacts.sh ]; then echo "packaging/release/verify-artifacts.sh is not available in this checkout" >&2; exit 1; fi
	packaging/release/verify-artifacts.sh --artifact-dir "$(RELEASE_DIR)" --version "$(VERSION)" --source-commit "$(SOURCE_COMMIT)" --require-macos $(RELEASE_SCOPE_FLAGS)

release-notes:
	@if [ ! -x packaging/release/make-notes.sh ]; then echo "packaging/release/make-notes.sh is not available in this checkout" >&2; exit 1; fi
	VERSION=$(VERSION) SOURCE_COMMIT=$(SOURCE_COMMIT) OUT_FILE="$(RELEASE_NOTES)" packaging/release/make-notes.sh

release-upload-draft:
	@if [ ! -f "$(RELEASE_NOTES)" ]; then echo "Release notes not found: $(RELEASE_NOTES). Run make release-notes and edit/check validation before upload." >&2; exit 1; fi
	@if [ ! -x packaging/release/upload-draft.sh ]; then echo "packaging/release/upload-draft.sh is not available in this checkout" >&2; exit 1; fi
	packaging/release/upload-draft.sh --repo "$(RELEASE_REPO)" --tag "$(RELEASE_TAG)" --target "$(SOURCE_COMMIT)" --title "$(RELEASE_TITLE)" --notes-file "$(RELEASE_NOTES)" --artifact-dir "$(RELEASE_DIR)" $(RELEASE_SCOPE_FLAGS)

release-status:
	gh release view "$(RELEASE_TAG)" --repo "$(RELEASE_REPO)"

clean:
	cargo clean
	$(MAKE) -C pam clean
	rm -rf target/package
