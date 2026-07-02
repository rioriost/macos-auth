#!/bin/sh
set -eu

# Prevent AppleDouble `._*` files from being emitted into package payloads
# when source files carry extended attributes/resource-fork metadata.
export COPYFILE_DISABLE=1

usage() {
  cat <<'USAGE'
Usage:
  build-pkg.sh [options]

Builds a macOS arm64 .pkg for the macos-auth agent.

Options:
  --version VERSION          Default: 0.1.0
  --out-dir PATH             Default: target/package/macos
  --prefix PATH              Default: /opt/homebrew
  --skip-build               Use existing Swift build output
  --sign-identity NAME       Developer ID Application identity for codesign
  --pkg-sign-identity NAME   Developer ID Installer identity for productsign
  -h, --help                 Show this help

Environment alternatives:
  CODESIGN_IDENTITY          Same as --sign-identity
  PKG_SIGN_IDENTITY          Same as --pkg-sign-identity
USAGE
}

version="0.1.0"
out_dir="target/package/macos"
prefix="/opt/homebrew"
skip_build=0
codesign_identity="${CODESIGN_IDENTITY:-}"
pkg_sign_identity="${PKG_SIGN_IDENTITY:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --prefix)
      prefix="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --sign-identity)
      codesign_identity="$2"
      shift 2
      ;;
    --pkg-sign-identity)
      pkg_sign_identity="$2"
      shift 2
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

case "$prefix" in
  /*) ;;
  *) echo "--prefix must be absolute" >&2; exit 2 ;;
esac

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

require_command swift
require_command pkgbuild
require_command productbuild
require_command sed
require_command cp

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

case "$(uname -m)" in
  arm64) ;;
  *) echo "macOS package builds are currently Apple Silicon arm64 only." >&2; exit 1 ;;
esac

if [ "$skip_build" -ne 1 ]; then
  swift build --package-path agent -c release
fi

agent_bin="agent/.build/release/macos-auth-agent"
if [ ! -x "$agent_bin" ]; then
  echo "agent binary not found or not executable: $agent_bin" >&2
  exit 1
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"
abs_out_dir=$(CDPATH= cd -- "$out_dir" && pwd)
work_dir=$(mktemp -d /tmp/macos-auth-pkg.XXXXXX)
payload_dir="$work_dir/payload"
component_pkg="$work_dir/macos-auth-component.pkg"
unsigned_pkg="$abs_out_dir/macos-auth-${version}-darwin-arm64.pkg"
signed_pkg="$abs_out_dir/macos-auth-${version}-darwin-arm64-signed.pkg"
metadata_file="$abs_out_dir/BUILD-METADATA.txt"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

mkdir -p \
  "$payload_dir$prefix/bin" \
  "$payload_dir$prefix/share/macos-auth/scripts" \
  "$payload_dir$prefix/share/macos-auth/launchd" \
  "$payload_dir$prefix/share/macos-auth/examples" \
  "$payload_dir$prefix/share/doc/macos-auth"

install_clean_file() {
  src="$1"
  dst="$2"
  mode="$3"
  cp -X "$src" "$dst"
  chmod "$mode" "$dst"
}

install_clean_file "$agent_bin" "$payload_dir$prefix/bin/macos-auth-agent" 0755
install_clean_file scripts/install-launchagent.sh "$payload_dir$prefix/share/macos-auth/scripts/install-launchagent.sh" 0755
install_clean_file scripts/uninstall-launchagent.sh "$payload_dir$prefix/share/macos-auth/scripts/uninstall-launchagent.sh" 0755
install_clean_file scripts/status-launchagent.sh "$payload_dir$prefix/share/macos-auth/scripts/status-launchagent.sh" 0755
install_clean_file agent/launchd/com.macos-auth.agent.plist "$payload_dir$prefix/share/macos-auth/launchd/com.macos-auth.agent.plist" 0644
install_clean_file packaging/macos/examples/agent-config.json.example "$payload_dir$prefix/share/macos-auth/examples/agent-config.json.example" 0644
install_clean_file packaging/macos/examples/ssh-config.sample "$payload_dir$prefix/share/macos-auth/examples/ssh-config.sample" 0644
install_clean_file README.md "$payload_dir$prefix/share/doc/macos-auth/README.md" 0644
install_clean_file agent/README.md "$payload_dir$prefix/share/doc/macos-auth/agent.md" 0644
install_clean_file LICENSE "$payload_dir$prefix/share/doc/macos-auth/LICENSE" 0644

find "$payload_dir" -name '._*' -delete
xattr -cr "$payload_dir" >/dev/null 2>&1 || true

if [ -n "$codesign_identity" ]; then
  codesign --force --timestamp --options runtime --sign "$codesign_identity" "$payload_dir$prefix/bin/macos-auth-agent"
else
  echo "Skipping codesign; pass --sign-identity or set CODESIGN_IDENTITY for distribution builds." >&2
fi

pkgbuild \
  --root "$payload_dir" \
  --identifier com.macos-auth.pkg \
  --version "$version" \
  --install-location / \
  --ownership recommended \
  --filter '/\\._[^/]*$' \
  "$component_pkg"

if [ -n "$pkg_sign_identity" ]; then
  productbuild \
    --package "$component_pkg" \
    --sign "$pkg_sign_identity" \
    "$signed_pkg"
  final_pkg="$signed_pkg"
else
  productbuild \
    --package "$component_pkg" \
    "$unsigned_pkg"
  final_pkg="$unsigned_pkg"
  echo "Built unsigned package; pass --pkg-sign-identity or set PKG_SIGN_IDENTITY for distribution builds." >&2
fi

cat > "$metadata_file" <<EOF_METADATA
version=$version
prefix=$prefix
artifact=$(basename -- "$final_pkg")
codesigned=$([ -n "$codesign_identity" ] && echo yes || echo no)
pkg_signed=$([ -n "$pkg_sign_identity" ] && echo yes || echo no)
source_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
EOF_METADATA

(
  cd "$abs_out_dir"
  shasum -a 256 "$(basename -- "$final_pkg")" > SHA256SUMS
)

pkgutil --check-signature "$final_pkg" || true
ls -l "$final_pkg" "$metadata_file" "$abs_out_dir/SHA256SUMS"
echo "Built $final_pkg"
