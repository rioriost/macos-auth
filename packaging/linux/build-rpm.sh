#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
cd "$repo_root"

version=${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' crates/helper/Cargo.toml | head -n 1)}
out_dir=${OUT_DIR:-target/package/rpm}
topdir="$repo_root/$out_dir/rpmbuild"
source_parent="$repo_root/$out_dir/source"
source_root="$source_parent/macos-auth-$version"
spec_template="packaging/linux/rpm/macos-auth.spec.in"
spec_file="$topdir/SPECS/macos-auth.spec"
source_archive="$topdir/SOURCES/macos-auth-$version.tar.gz"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

require_command cargo
require_command make
require_command cc
require_command rpmbuild
require_command sed
require_command tar

rm -rf "$topdir" "$source_parent"
mkdir -p "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS" "$source_root"

cp Cargo.toml Cargo.lock LICENSE README.md "$source_root/"
cp -R crates "$source_root/crates"
cp -R pam "$source_root/pam"
mkdir -p "$source_root/docs"
cp docs/helper.md docs/pam-testing.md "$source_root/docs/"

sed -e "s/@VERSION@/$version/g" "$spec_template" > "$spec_file"
tar -C "$source_parent" -czf "$source_archive" "macos-auth-$version"

rpmbuild ${RPMBUILD_OPTS:-} --define "_topdir $topdir" -bb "$spec_file"

find "$topdir/RPMS" -type f -name '*.rpm' -exec cp {} "$out_dir/" \;
find "$out_dir" -maxdepth 1 -type f -name '*.rpm' -print
