#!/usr/bin/env python3
"""Fail-closed draft-only GitHub upload. Never publishes a release."""

import argparse
import json
from pathlib import Path
import subprocess
import sys

import artifacts


def query_draft(repo, tag):
    result = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft"],
        text=True, capture_output=True,
    )
    if result.returncode == 0:
        response = json.loads(result.stdout)
        if not isinstance(response, dict):
            raise ValueError("GitHub returned an invalid draft-state response")
        value = response.get("isDraft")
        if not isinstance(value, bool):
            raise ValueError("GitHub returned an invalid isDraft value")
        return value
    # A failed view alone is NOT evidence that a release is missing: authenticate
    # and enumerate all visible releases successfully before deciding to create.
    listing = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"],
        text=True, capture_output=True,
    )
    if listing.returncode:
        raise ValueError("cannot determine release state; GitHub query failed (no mutations made)")
    pages = json.loads(listing.stdout)
    if not isinstance(pages, list) or not pages or not all(isinstance(page, list) for page in pages):
        raise ValueError("invalid GitHub release listing")
    for page in pages:
        for release in page:
            if not isinstance(release, dict) or not isinstance(release.get("tag_name"), str):
                raise ValueError("invalid GitHub release listing entry")
            if release["tag_name"] == tag:
                raise ValueError("release exists but its draft-state query failed; refusing mutation")
    return None


def require_draft(repo, tag):
    if query_draft(repo, tag) is not True:
        raise ValueError("refusing to modify a published or missing release")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "tag", "target", "title", "notes-file", "artifact-dir"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--macos-only", action="store_true",
                        help="explicit macOS-only draft; never automatically substitutes for the full release gate")
    args = parser.parse_args()
    if not Path(args.notes_file).is_file() or not Path(args.artifact_dir).is_dir():
        raise ValueError("notes file and artifact directory must exist")
    if not args.tag.startswith("v"):
        raise ValueError("release tag must be v<VERSION>")
    state = query_draft(args.repo, args.tag)
    if state is False:
        raise ValueError("refusing to modify a published release; use a new version/tag")
    version = args.tag[1:]
    artifacts.verify(args.artifact_dir, version, args.target, require_macos=True, macos_only=args.macos_only)
    target = artifacts.git(artifacts.ROOT, "rev-parse", "--verify", args.target + "^{commit}")
    common = ["--repo", args.repo, "--target", target, "--title", args.title,
              "--notes-file", args.notes_file]
    # Recheck immediately before each mutation; do not publish concurrently.
    if state is True:
        require_draft(args.repo, args.tag)
        subprocess.run(["gh", "release", "edit", args.tag, *common], check=True)
    else:
        if query_draft(args.repo, args.tag) is not None:
            raise ValueError("release appeared during validation; refusing mutation")
        subprocess.run(["gh", "release", "create", args.tag, "--draft", *common], check=True)
    require_draft(args.repo, args.tag)
    directory = Path(args.artifact_dir)
    index = json.loads((directory / "BUILD-METADATA.txt").read_text())
    paths = []
    for entry in index["artifacts"]:
        package = directory / entry["artifact"]
        paths.extend([package, artifacts.metadata_path(package), artifacts.checksum_path(package)])
    paths.extend(directory / name for name in (
        "SHA256SUMS-darwin-arm64", "BUILD-METADATA.txt", "BUILD-METADATA-darwin-arm64.txt",
    ))
    if not args.macos_only:
        paths.append(directory / "SHA256SUMS")
    subprocess.run(["gh", "release", "upload", args.tag, *map(str, paths),
                    "--repo", args.repo, "--clobber"], check=True)
    subprocess.run(["gh", "release", "view", args.tag, "--repo", args.repo], check=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
