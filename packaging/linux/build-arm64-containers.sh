#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
cd "$repo_root"

podman_bin=${PODMAN:-podman}
version=${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' crates/helper/Cargo.toml | head -n 1)}
source_ref=${SOURCE_REF:-HEAD}
out_dir=${OUT_DIR:-target/package/arm64-containers}
work_dir=${WORK_DIR:-target/package/arm64-container-work}
provenance="$repo_root/packaging/release/artifacts.py"

case "$(uname -m)" in
  arm64|aarch64) ;;
  *)
    echo "This script builds arm64/aarch64 packages and requires an arm64/aarch64 builder." >&2
    exit 1
    ;;
esac

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

prepare_source() {
  label="$1"
  src_dir="$abs_work_dir/src-$label"
  git clone --quiet --no-local "$repo_root" "$src_dir"
  git -C "$src_dir" checkout --quiet --detach "$commit"
  printf '%s\n' "$src_dir"
}

run_ubuntu_build() {
  image="$1"
  label="$2"
  src_dir=$(prepare_source "$label")
  "$podman_bin" run --rm --platform linux/arm64 \
    -e VERSION="$version" -e OUT_DIR=/out \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/src \
    -v "$src_dir:/src:Z" \
    -v "$abs_out_dir:/out:Z" \
    "$image" \
    sh -eu -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y build-essential cargo dpkg-dev git libpam0g-dev make rustc rustfmt ca-certificates python3; cd /src; make check; make package-deb'
}

run_rhel_build() {
  image="$1"
  label="$2"
  src_dir=$(prepare_source "$label")
  "$podman_bin" run --rm --platform linux/arm64 \
    -e VERSION="$version" -e OUT_DIR=/out \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/src \
    -v "$src_dir:/src:Z" \
    -v "$abs_out_dir:/out:Z" \
    "$image" \
    sh -eu -c 'dnf install -y cargo gcc git make pam-devel rpm-build rust ca-certificates python3; cd /src; cargo test --locked; make -C pam check; make shell-check; make package-rpm'
}

require_command "$podman_bin"
require_command git
require_command tar
require_command sed
require_command sha256sum
require_command python3

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "release builds require a clean committed source tree" >&2
  exit 1
fi
commit=$(git rev-parse --verify "$source_ref^{commit}")
mkdir -p "$out_dir" "$work_dir"
abs_out_dir=$(CDPATH= cd "$out_dir" && pwd)
abs_work_dir=$(python3 -B "$provenance" stage "$work_dir")
trap 'rm -rf "$abs_work_dir"' EXIT
trap 'exit 1' INT TERM

run_ubuntu_build docker.io/library/ubuntu:24.04 ubuntu24.04
run_ubuntu_build docker.io/library/ubuntu:25.10 ubuntu25.10
run_rhel_build registry.access.redhat.com/ubi9/ubi:9.7 rhel9
run_rhel_build registry.access.redhat.com/ubi10/ubi:10.1 rhel10

(
  cd "$abs_out_dir"
  sha256sum *.deb *.rpm | sort > SHA256SUMS
  chmod 0644 SHA256SUMS *.deb *.rpm *.metadata.json *.sha256
  ls -l
  cat SHA256SUMS
)
