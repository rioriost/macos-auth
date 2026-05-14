#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
cd "$repo_root"

version=${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' crates/helper/Cargo.toml | head -n 1)}
out_dir=${OUT_DIR:-target/package/deb}
stage_dir="$out_dir/stage"
control_template="packaging/linux/deb/control.in"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

require_command cargo
require_command make
require_command cc
require_command dpkg
require_command dpkg-deb
require_command sed
require_command awk
require_command du

arch=$(dpkg --print-architecture)
if command -v dpkg-architecture >/dev/null 2>&1; then
  multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
else
  case "$arch" in
    amd64) multiarch=x86_64-linux-gnu ;;
    arm64) multiarch=aarch64-linux-gnu ;;
    *)
      echo "unable to determine Debian multiarch path for architecture: $arch" >&2
      echo "install dpkg-dev or set up dpkg-architecture" >&2
      exit 1
      ;;
  esac
fi

pkgroot="$stage_dir/macos-auth_${version}_${arch}"
artifact="$out_dir/macos-auth_${version}_${arch}.deb"

cargo build --release --locked
make -C pam

rm -rf "$pkgroot"
mkdir -p "$pkgroot/DEBIAN"

install -D -m 0755 target/release/macos-auth-helper "$pkgroot/usr/bin/macos-auth-helper"
install -D -m 0644 pam/pam_macos_auth.so "$pkgroot/usr/lib/$multiarch/security/pam_macos_auth.so"
install -D -m 0644 LICENSE "$pkgroot/usr/share/doc/macos-auth/copyright"
install -D -m 0644 README.md "$pkgroot/usr/share/doc/macos-auth/README.md"
install -D -m 0644 docs/helper.md "$pkgroot/usr/share/doc/macos-auth/helper.md"
install -D -m 0644 docs/pam-testing.md "$pkgroot/usr/share/doc/macos-auth/pam-testing.md"
install -D -m 0644 pam/README.md "$pkgroot/usr/share/doc/macos-auth/pam.md"
install -D -m 0644 pam/examples/macos-auth-test "$pkgroot/usr/share/macos-auth/examples/macos-auth-test"
install -D -m 0644 pam/examples/sudo-snippet "$pkgroot/usr/share/macos-auth/examples/sudo-snippet"

installed_size=$(du -sk "$pkgroot/usr" | awk '{print $1}')
sed \
  -e "s/@VERSION@/$version/g" \
  -e "s/@ARCH@/$arch/g" \
  -e "s/@INSTALLED_SIZE@/$installed_size/g" \
  "$control_template" > "$pkgroot/DEBIAN/control"

find "$pkgroot" -type d -exec chmod 0755 {} \;

dpkg-deb --build --root-owner-group "$pkgroot" "$artifact"

echo "built $artifact"
