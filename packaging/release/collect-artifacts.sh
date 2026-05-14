#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  collect-artifacts.sh [options] --source DIR_OR_REMOTE ...

Collects release artifacts from local directories or scp-compatible remote
sources into one release directory and regenerates checksum/metadata files.

Options:
  --out-dir DIR          Default: target/package/release
  --version VERSION      Default: 0.1.0
  --source SOURCE        Local directory or scp remote directory, repeatable
  --clean                Remove OUT_DIR before collecting
  -h, --help             Show this help

Environment:
  RELEASE_ARTIFACT_SOURCES may contain whitespace-separated sources when
  --source is not provided.

Examples:
  collect-artifacts.sh --source target/package/x86_64-containers --source target/package/macos
  RELEASE_ARTIFACT_SOURCES="host:/path/to/artifacts local/dir" make release-collect
USAGE
}

out_dir="target/package/release"
version="0.1.0"
clean=0
sources=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --version)
      version="$2"
      shift 2
      ;;
    --source)
      sources="$sources
$2"
      shift 2
      ;;
    --clean)
      clean=1
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

if [ -z "$sources" ] && [ -n "${RELEASE_ARTIFACT_SOURCES:-}" ]; then
  for source in $RELEASE_ARTIFACT_SOURCES; do
    sources="$sources
$source"
  done
fi

if [ -z "$sources" ]; then
  usage >&2
  exit 2
fi

if [ "$clean" -eq 1 ]; then
  rm -rf "$out_dir"
fi
mkdir -p "$out_dir"

copy_local_source() {
  src="$1"
  if [ ! -d "$src" ]; then
    echo "source directory not found: $src" >&2
    exit 1
  fi
  find "$src" -maxdepth 1 -type f \( \
    -name '*.deb' -o \
    -name '*.rpm' -o \
    -name '*.pkg' \
  \) ! -name '*-signed.pkg' -exec cp {} "$out_dir" \;
}

copy_remote_source() {
  src="$1"
  # scp returns non-zero when a glob has no matches. Keep each pattern optional.
  scp -q "$src"/*.deb "$out_dir"/ 2>/dev/null || true
  scp -q "$src"/*.rpm "$out_dir"/ 2>/dev/null || true
  tmp_dir=$(mktemp -d /tmp/macos-auth-collect.XXXXXX)
  scp -q "$src"/*.pkg "$tmp_dir"/ 2>/dev/null || true
  find "$tmp_dir" -maxdepth 1 -type f -name '*.pkg' ! -name '*-signed.pkg' -exec cp {} "$out_dir" \;
  rm -rf "$tmp_dir"
}

printf '%s
' "$sources" | while IFS= read -r source; do
  [ -n "$source" ] || continue
  case "$source" in
    *:*) copy_remote_source "$source" ;;
    *) copy_local_source "$source" ;;
  esac
done

package_count=$(find "$out_dir" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' -o -name '*.pkg' \) | wc -l | tr -d ' ')
if [ "$package_count" = "0" ]; then
  echo "no package artifacts collected" >&2
  exit 1
fi

source_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
{
  echo "version=$version"
  echo "source_commit=$source_commit"
  echo "generated_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "artifact_count=$package_count"
  echo "sources<<EOF"
  printf '%s
' "$sources" | sed '/^$/d'
  echo "EOF"
} > "$out_dir/BUILD-METADATA.txt"

(
  cd "$out_dir"
  if find . -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) | grep -q .; then
    find . -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) -print0 \
      | xargs -0 shasum -a 256 \
      | sed 's#  ./#  #' \
      | sort > SHA256SUMS
  fi
  if find . -maxdepth 1 -type f -name '*darwin-arm64.pkg' | grep -q .; then
    find . -maxdepth 1 -type f -name '*darwin-arm64.pkg' -print0 \
      | xargs -0 shasum -a 256 \
      | sed 's#  ./#  #' \
      | sort > SHA256SUMS-darwin-arm64
    cp BUILD-METADATA.txt BUILD-METADATA-darwin-arm64.txt
  fi
  chmod 0644 ./*
  ls -l
)
