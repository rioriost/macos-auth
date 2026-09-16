#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
cd "$repo_root"

version=${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' crates/helper/Cargo.toml | head -n 1)}
out_dir=${OUT_DIR:-target/package/deb}
provenance="$repo_root/packaging/release/artifacts.py"
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
require_command git
require_command python3
require_command tar

arch=$(dpkg --print-architecture)
distro=$(python3 -B "$provenance" distro deb)
artifact_name=$(python3 -B "$provenance" name --version "$version" --distro "$distro" --arch "$arch")
mkdir -p "$out_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd)
artifact="$out_dir/$artifact_name"
if [ -e "$artifact" ] || [ -e "$artifact.metadata.json" ] || [ -e "$artifact.sha256" ]; then
  echo "output already exists; use a fresh OUT_DIR: $artifact" >&2
  exit 1
fi
stage_dir=$(python3 -B "$provenance" stage "$out_dir")
trap 'rm -rf "$stage_dir"' EXIT
trap 'exit 1' INT TERM
source_dir=$(python3 -B "$provenance" snapshot --repo "$repo_root" --version "$version" --stage "$stage_dir")
cd "$source_dir"

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

pkgroot="$stage_dir/pkgroot"

cargo build --release --locked
make -C pam

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
install -D -m 0644 packaging/linux/examples/config.toml.sample "$pkgroot/usr/share/macos-auth/examples/config.toml.sample"
install -D -m 0644 packaging/linux/examples/ssh-config.sample "$pkgroot/usr/share/macos-auth/examples/ssh-config.sample"

installed_size=$(du -sk "$pkgroot/usr" | awk '{print $1}')
sed \
  -e "s/@VERSION@/$version/g" \
  -e "s/@ARCH@/$arch/g" \
  -e "s/@INSTALLED_SIZE@/$installed_size/g" \
  "$control_template" > "$pkgroot/DEBIAN/control"

find "$pkgroot" -type d -exec chmod 0755 {} \;

dpkg-deb --build --root-owner-group "$pkgroot" "$artifact"
python3 -B "$provenance" record --snapshot "$stage_dir/source.json" \
  --artifact "$artifact" --distro "$distro" --arch "$arch"

echo "built $artifact"
