#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  upload-draft.sh --repo OWNER/REPO --tag TAG --target COMMIT --title TITLE --notes-file PATH --artifact-dir DIR

Creates or updates a GitHub draft release and uploads release artifacts.
Existing assets with the same names are overwritten.

Options:
  --repo OWNER/REPO       GitHub repository, e.g. rioriost/macos-auth
  --tag TAG               Release tag, e.g. v0.1.0
  --target COMMIT         Target commitish or full commit SHA
  --title TITLE           Release title
  --notes-file PATH       Release notes Markdown file
  --artifact-dir DIR      Directory containing assets to upload
  -h, --help              Show this help
USAGE
}

repo=""
tag=""
target=""
title=""
notes_file=""
artifact_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --tag)
      tag="$2"
      shift 2
      ;;
    --target)
      target="$2"
      shift 2
      ;;
    --title)
      title="$2"
      shift 2
      ;;
    --notes-file)
      notes_file="$2"
      shift 2
      ;;
    --artifact-dir)
      artifact_dir="$2"
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

if [ -z "$repo" ] || [ -z "$tag" ] || [ -z "$target" ] || [ -z "$title" ] || [ -z "$notes_file" ] || [ -z "$artifact_dir" ]; then
  usage >&2
  exit 2
fi

if [ ! -f "$notes_file" ]; then
  echo "notes file not found: $notes_file" >&2
  exit 1
fi

if [ ! -d "$artifact_dir" ]; then
  echo "artifact dir not found: $artifact_dir" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required" >&2
  exit 1
fi

assets=$(find "$artifact_dir" -maxdepth 1 -type f \( \
  -name '*.deb' -o \
  -name '*.rpm' -o \
  -name '*.pkg' -o \
  -name 'SHA256SUMS*' -o \
  -name 'BUILD-METADATA*.txt' \
\) | sort)

if [ -z "$assets" ]; then
  echo "no release assets found in $artifact_dir" >&2
  exit 1
fi

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release edit "$tag" \
    --repo "$repo" \
    --target "$target" \
    --title "$title" \
    --notes-file "$notes_file"
else
  gh release create "$tag" \
    --repo "$repo" \
    --target "$target" \
    --draft \
    --title "$title" \
    --notes-file "$notes_file"
fi

# shellcheck disable=SC2086
# Intentional word splitting: assets is a newline-delimited list of file paths without newlines.
gh release upload "$tag" $assets --repo "$repo" --clobber

gh release view "$tag" --repo "$repo"
