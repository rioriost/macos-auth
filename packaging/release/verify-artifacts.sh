#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  verify-artifacts.sh [options]

Verifies that a release artifact directory contains the expected package names
and that checksum files match. On macOS, also verifies the notarized pkg when
present.

Options:
  --artifact-dir DIR      Default: target/package/release
  --version VERSION       Default: 0.1.0
  --require-macos         Require darwin-arm64 pkg and verify its checksum
  -h, --help              Show this help
USAGE
}

artifact_dir="target/package/release"
version="0.1.0"
require_macos=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-dir)
      artifact_dir="$2"
      shift 2
      ;;
    --version)
      version="$2"
      shift 2
      ;;
    --require-macos)
      require_macos=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$artifact_dir" ]; then
  echo "artifact dir not found: $artifact_dir" >&2
  exit 1
fi

missing=0
require_file() {
  file="$artifact_dir/$1"
  if [ ! -f "$file" ]; then
    echo "missing artifact: $1" >&2
    missing=1
  fi
}

require_file "macos-auth_${version}_ubuntu24.04_amd64.deb"
require_file "macos-auth_${version}_ubuntu24.04_arm64.deb"
require_file "macos-auth_${version}_ubuntu25.10_amd64.deb"
require_file "macos-auth_${version}_ubuntu25.10_arm64.deb"
require_file "macos-auth-${version}-1.rhel9.x86_64.rpm"
require_file "macos-auth-${version}-1.rhel9.aarch64.rpm"
require_file "macos-auth-${version}-1.rhel10.x86_64.rpm"
require_file "macos-auth-${version}-1.rhel10.aarch64.rpm"
require_file "SHA256SUMS"
require_file "BUILD-METADATA.txt"

if [ "$require_macos" -eq 1 ]; then
  require_file "macos-auth-${version}-darwin-arm64.pkg"
  require_file "SHA256SUMS-darwin-arm64"
  require_file "BUILD-METADATA-darwin-arm64.txt"
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

(
  cd "$artifact_dir"
  shasum -a 256 -c SHA256SUMS
  if [ "$require_macos" -eq 1 ]; then
    shasum -a 256 -c SHA256SUMS-darwin-arm64
  fi
)

if [ "$require_macos" -eq 1 ] && command -v spctl >/dev/null 2>&1 && command -v pkgutil >/dev/null 2>&1; then
  pkgutil --check-signature "$artifact_dir/macos-auth-${version}-darwin-arm64.pkg"
  spctl --assess --type install -vv "$artifact_dir/macos-auth-${version}-darwin-arm64.pkg"
fi

echo "release artifacts verified: $artifact_dir"
