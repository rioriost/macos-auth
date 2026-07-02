#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  notarize-pkg.sh --pkg PATH [options]

Submits a signed macOS .pkg to Apple notary service, staples the ticket,
verifies Gatekeeper acceptance, and optionally writes a cask-named copy.

Options:
  --pkg PATH                  Signed pkg to notarize and staple
  --keychain-profile NAME     Default: macos-auth-notary
  --final-pkg PATH            Optional final copy path after stapling
  --sha256-file PATH          Optional checksum output for final pkg
  -h, --help                  Show this help
USAGE
}

pkg_path=""
keychain_profile="macos-auth-notary"
final_pkg=""
sha256_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pkg)
      pkg_path="$2"
      shift 2
      ;;
    --keychain-profile)
      keychain_profile="$2"
      shift 2
      ;;
    --final-pkg)
      final_pkg="$2"
      shift 2
      ;;
    --sha256-file)
      sha256_file="$2"
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

if [ -z "$pkg_path" ]; then
  usage >&2
  exit 2
fi

if [ ! -f "$pkg_path" ]; then
  echo "pkg not found: $pkg_path" >&2
  exit 1
fi

xcrun notarytool submit "$pkg_path" \
  --keychain-profile "$keychain_profile" \
  --wait

xcrun stapler staple "$pkg_path"
xcrun stapler validate "$pkg_path"
pkgutil --check-signature "$pkg_path"
spctl --assess --type install -vv "$pkg_path"

if [ -n "$final_pkg" ]; then
  mkdir -p "$(dirname -- "$final_pkg")"
  cp "$pkg_path" "$final_pkg"
  pkgutil --check-signature "$final_pkg"
  spctl --assess --type install -vv "$final_pkg"
  if [ -n "$sha256_file" ]; then
    (cd "$(dirname -- "$final_pkg")" && shasum -a 256 "$(basename -- "$final_pkg")") > "$sha256_file"
  fi
elif [ -n "$sha256_file" ]; then
  (cd "$(dirname -- "$pkg_path")" && shasum -a 256 "$(basename -- "$pkg_path")") > "$sha256_file"
fi
