#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
cd "$repo_root"

podman_bin=${PODMAN:-podman}
version=${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' crates/helper/Cargo.toml | head -n 1)}
source_ref=${SOURCE_REF:-HEAD}
out_dir=${OUT_DIR:-target/package/x86_64-containers}
work_dir=${WORK_DIR:-target/package/x86_64-container-work}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

prepare_source() {
  label="$1"
  src_dir="$work_dir/src-$label"
  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  git archive "$source_ref" | tar -C "$src_dir" -xf -
  printf '%s\n' "$src_dir"
}

run_ubuntu_build() {
  image="$1"
  label="$2"
  src_dir=$(prepare_source "$label")
  artifact="macos-auth_${version}_${label}_amd64.deb"

  "$podman_bin" run --rm \
    -v "$src_dir:/src:Z" \
    -v "$abs_out_dir:/out:Z" \
    "$image" \
    sh -eu -c "export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y build-essential cargo dpkg-dev git libpam0g-dev make rustc rustfmt ca-certificates; cd /src; make check; make package-deb; cp target/package/deb/*.deb /out/$artifact; sha256sum /out/$artifact"
}

run_rhel_build() {
  image="$1"
  label="$2"
  src_dir=$(prepare_source "$label")
  artifact="macos-auth-${version}-1.${label}.x86_64.rpm"

  "$podman_bin" run --rm \
    -v "$src_dir:/src:Z" \
    -v "$abs_out_dir:/out:Z" \
    "$image" \
    sh -eu -c "dnf install -y cargo gcc git make pam-devel rpm-build rust ca-certificates; cd /src; cargo test --locked; make -C pam check; sh -n scripts/check.sh; sh -n scripts/linux-dev-setup.sh; sh -n scripts/linux-install-dev.sh; sh -n packaging/linux/build-deb.sh; sh -n packaging/linux/build-rpm.sh; sh -n packaging/linux/build-x86_64-containers.sh; make package-rpm; cp target/package/rpm/*.rpm /out/$artifact; sha256sum /out/$artifact"
}

require_command "$podman_bin"
require_command git
require_command tar
require_command sed
require_command sha256sum

case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    echo "This script builds x86_64/amd64 packages and must run on an x86_64 host." >&2
    exit 1
    ;;
esac

rm -rf "$out_dir" "$work_dir"
mkdir -p "$out_dir" "$work_dir"
abs_out_dir=$(CDPATH= cd "$out_dir" && pwd)
commit=$(git rev-parse --short=12 "$source_ref")

cat > "$abs_out_dir/BUILD-METADATA.txt" <<EOF_META
source_ref=$source_ref
source_commit=$commit
version=$version
host_arch=$(uname -m)
ubuntu_24_04_image=docker.io/library/ubuntu:24.04
ubuntu_25_10_image=docker.io/library/ubuntu:25.10
rhel_9_image=registry.access.redhat.com/ubi9/ubi:9.7
rhel_10_image=registry.access.redhat.com/ubi10/ubi:10.1
EOF_META

run_ubuntu_build docker.io/library/ubuntu:24.04 ubuntu24.04
run_ubuntu_build docker.io/library/ubuntu:25.10 ubuntu25.10
run_rhel_build registry.access.redhat.com/ubi9/ubi:9.7 rhel9
run_rhel_build registry.access.redhat.com/ubi10/ubi:10.1 rhel10

(
  cd "$abs_out_dir"
  sha256sum *.deb *.rpm | sort > SHA256SUMS
  chmod 0644 BUILD-METADATA.txt SHA256SUMS *.deb *.rpm
  ls -l
  cat SHA256SUMS
)
