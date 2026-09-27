#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
cd "$repo_root"

version=${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' crates/helper/Cargo.toml | head -n 1)}
out_dir=${OUT_DIR:-target/package/rpm}
provenance="$repo_root/packaging/release/artifacts.py"
spec_template="packaging/linux/rpm/macos-auth.spec.in"

case "$(uname -m)" in
  arm64|aarch64) ;;
  *) echo "Linux package builds require an arm64/aarch64 builder." >&2; exit 1 ;;
esac

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
require_command rpm
require_command sed
require_command tar
require_command git
require_command python3

distro=$(python3 -B "$provenance" distro rpm)
arch=$(rpm --eval '%{_arch}')
artifact_name=$(python3 -B "$provenance" name --version "$version" --distro "$distro" --arch "$arch")
mkdir -p "$out_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd)
artifact="$out_dir/$artifact_name"
if [ -e "$artifact" ] || [ -e "$artifact.metadata.json" ] || [ -e "$artifact.sha256" ]; then
  echo "output already exists; use a fresh OUT_DIR: $artifact" >&2
  exit 1
fi
work_dir=$(python3 -B "$provenance" stage "$out_dir")
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' INT TERM
source_dir=$(python3 -B "$provenance" snapshot --repo "$repo_root" --version "$version" --stage "$work_dir")
topdir="$work_dir/rpmbuild"
source_parent="$work_dir/archive"
source_root="$source_parent/macos-auth-$version"
spec_file="$topdir/SPECS/macos-auth.spec"
source_archive="$topdir/SOURCES/macos-auth-$version.tar.gz"
mkdir -p "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS" "$source_parent"
mv "$source_dir" "$source_root"
cd "$source_root"

sed -e "s/@VERSION@/$version/g" "$spec_template" > "$spec_file"
tar -C "$source_parent" -czf "$source_archive" "macos-auth-$version"

rpmbuild ${RPMBUILD_OPTS:-} --define "_topdir $topdir" --define "dist .$distro" -bb "$spec_file"

built="$topdir/RPMS/$arch/$artifact_name"
if [ ! -f "$built" ]; then
  echo "rpmbuild did not produce expected target: $built" >&2
  exit 1
fi
cp "$built" "$artifact"
python3 -B "$provenance" record --snapshot "$work_dir/source.json" \
  --artifact "$artifact" --distro "$distro" --arch "$arch"
echo "built $artifact"
