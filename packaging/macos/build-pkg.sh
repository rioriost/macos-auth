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
  --version VERSION          Default: 0.1.2
  --out-dir PATH             Default: target/package/macos
  --prefix PATH              Default: /opt/homebrew
  --development              Allow dirty-source unsigned local builds (not releasable)
  --sign-identity NAME       Developer ID Application identity for codesign
  --pkg-sign-identity NAME   Developer ID Installer identity for productsign
  -h, --help                 Show this help

Environment alternatives:
  CODESIGN_IDENTITY          Same as --sign-identity
  PKG_SIGN_IDENTITY          Same as --pkg-sign-identity
USAGE
}

version="0.1.2"
out_dir="target/package/macos"
prefix="/opt/homebrew"
development=0
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
      echo "--skip-build is unsupported: existing binaries cannot prove source provenance" >&2
      exit 2
      ;;
    --development)
      development=1
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
require_command python3
require_command git
require_command tar

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
provenance="$repo_root/packaging/release/artifacts.py"
cd "$repo_root"

case "$(uname -m)" in
  arm64) ;;
  *) echo "macOS package builds are currently Apple Silicon arm64 only." >&2; exit 1 ;;
esac

if [ "$development" -eq 1 ] && { [ -n "$codesign_identity" ] || [ -n "$pkg_sign_identity" ]; }; then
  echo "--development is restricted to unsigned local builds" >&2
  exit 2
fi
if { [ -n "$codesign_identity" ] && [ -z "$pkg_sign_identity" ]; } ||
   { [ -z "$codesign_identity" ] && [ -n "$pkg_sign_identity" ]; }; then
  echo "distribution builds require both application and installer signing identities" >&2
  exit 2
fi

mkdir -p "$out_dir"
abs_out_dir=$(CDPATH= cd -- "$out_dir" && pwd)
state=unsigned
[ -z "$pkg_sign_identity" ] || state=signed
artifact_name=$(python3 -B "$provenance" name --version "$version" --distro darwin --arch arm64 --state "$state")
final_pkg="$abs_out_dir/$artifact_name"
if [ -e "$final_pkg" ] || [ -e "$final_pkg.metadata.json" ] || [ -e "$final_pkg.sha256" ]; then
  echo "output already exists; use a fresh --out-dir: $final_pkg" >&2
  exit 1
fi
work_dir=$(python3 -B "$provenance" stage "$abs_out_dir")
payload_dir="$work_dir/payload"
component_pkg="$work_dir/macos-auth-component.pkg"
candidate_pkg="$work_dir/$artifact_name"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

if [ "$development" -eq 1 ]; then
  source_dir=$(python3 -B "$provenance" snapshot --repo "$repo_root" --version "$version" --stage "$work_dir" --development)
else
  source_dir=$(python3 -B "$provenance" snapshot --repo "$repo_root" --version "$version" --stage "$work_dir")
fi
cd "$source_dir"
swift build --package-path agent -c release
agent_bin="agent/.build/release/macos-auth-agent"
if [ ! -x "$agent_bin" ]; then
  echo "agent binary not found or not executable: $agent_bin" >&2
  exit 1
fi

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
    "$candidate_pkg"
  pkgutil --check-signature "$candidate_pkg"
else
  productbuild \
    --package "$component_pkg" \
    "$candidate_pkg"
  echo "Built unsigned package; pass --pkg-sign-identity or set PKG_SIGN_IDENTITY for distribution builds." >&2
fi

python3 -B "$provenance" record --snapshot "$work_dir/source.json" \
  --artifact "$candidate_pkg" --distro darwin --arch arm64 --state "$state" --prefix "$prefix"
cp "$candidate_pkg" "$candidate_pkg.metadata.json" "$candidate_pkg.sha256" "$abs_out_dir/"
ls -l "$final_pkg" "$final_pkg.metadata.json" "$final_pkg.sha256"
echo "Built $final_pkg"
