#!/usr/bin/env python3
"""Names and builder provenance shared by package and release scripts (stdlib only)."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
VERSION = "0.1.2"
SCHEMA = 1
LINUX_TARGETS = (
    ("ubuntu24.04", "amd64"), ("ubuntu24.04", "arm64"),
    ("ubuntu25.10", "amd64"), ("ubuntu25.10", "arm64"),
    ("rhel9", "x86_64"), ("rhel9", "aarch64"),
    ("rhel10", "x86_64"), ("rhel10", "aarch64"),
)


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.PIPE)


def git(repo, *args):
    return run("git", "-C", str(repo), *args).decode().strip()


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def json_write(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def artifact_name(version, distro, arch, state="linux"):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.]+)?", version):
        raise ValueError("invalid package version")
    if (distro, arch) in LINUX_TARGETS:
        if state != "linux":
            raise ValueError("invalid Linux artifact state")
        if distro.startswith("ubuntu"):
            return f"macos-auth_{version}_{distro}_{arch}.deb"
        return f"macos-auth-{version}-1.{distro}.{arch}.rpm"
    if (distro, arch) == ("darwin", "arm64") and state in ("unsigned", "signed", "notarized"):
        suffix = "-signed" if state == "signed" else ""
        return f"macos-auth-{version}-darwin-arm64{suffix}.pkg"
    raise ValueError(f"unsupported target: {distro}/{arch}")


def host_distro(package_type):
    values = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip("\"'")
    distro_id = values.get("ID", "")
    version = values.get("VERSION_ID", "")
    if package_type == "deb" and distro_id == "ubuntu" and version in ("24.04", "25.10"):
        return "ubuntu" + version
    if package_type == "rpm" and distro_id in ("rhel", "centos", "rocky", "almalinux"):
        major = version.split(".")[0]
        if major in ("9", "10"):
            return "rhel" + major
    raise ValueError(f"unsupported release builder OS: {distro_id} {version}")


def source_description(repo, version, revision="HEAD", require_version=True):
    commit = git(repo, "rev-parse", "--verify", revision + "^{commit}")
    manifest = git(repo, "show", commit + ":crates/helper/Cargo.toml")
    match = re.search(r'^version = "([^"]+)"$', manifest, re.MULTILINE)
    if require_version and (not match or match[1] != version):
        raise ValueError("requested version does not match the committed helper manifest")
    archive = run("git", "-C", str(repo), "archive", "--format=tar", commit)
    description = {
        "source_commit": commit,
        "source_tree": git(repo, "rev-parse", commit + "^{tree}"),
        "source_archive_sha256": hashlib.sha256(archive).hexdigest(),
        "source_clean": True,
    }
    return description, archive


def stage(parent):
    parent = Path(parent).resolve()
    parent.mkdir(parents=True, exist_ok=True)
    directory = parent / (".macos-auth-stage-" + uuid.uuid4().hex)
    directory.mkdir()
    return directory


def snapshot(repo, version, directory, development=False):
    repo, directory = Path(repo).resolve(), Path(directory).resolve()
    dirty = bool(git(repo, "status", "--porcelain", "--untracked-files=all"))
    if dirty and not development:
        raise ValueError("release builds require a clean committed source tree (including untracked files)")
    description, archive = source_description(repo, version, require_version=not development)
    source = directory / "source"
    source.mkdir()
    subprocess.run(["tar", "-xf", "-", "-C", str(source)], input=archive, check=True)
    if development:
        # Overlay tracked modifications and non-ignored new files, never old build outputs.
        files = run("git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard")
        for name in files.decode().split("\0"):
            if not name:
                continue
            original, destination = repo / name, source / name
            if destination.is_symlink() or destination.is_file():
                destination.unlink()
            if original.is_symlink() or original.is_file():
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, destination, follow_symlinks=False)
        description["source_clean"] = False
        description["source_archive_sha256"] = None
        manifest = (source / "crates/helper/Cargo.toml").read_text()
        match = re.search(r'^version = "([^"]+)"$', manifest, re.MULTILINE)
        if not match or match[1] != version:
            raise ValueError("development version does not match the snapshot helper manifest")
    contents = hashlib.sha256()
    for path in sorted(source.rglob("*")):
        if path.is_file() or path.is_symlink():
            contents.update(str(path.relative_to(source)).encode() + b"\0")
            contents.update(str(path.lstat().st_mode).encode() + b"\0")
            contents.update(os.readlink(path).encode() if path.is_symlink() else path.read_bytes())
    description["snapshot_sha256"] = contents.hexdigest()
    data = {"schema_version": SCHEMA, "version": version, "source": description}
    json_write(directory / "source.json", data)
    return source


def metadata_path(artifact):
    return Path(str(artifact) + ".metadata.json")


def checksum_path(artifact):
    return Path(str(artifact) + ".sha256")


def read_record(artifact, expected=None, version=None, release=True):
    artifact = Path(artifact)
    if artifact.is_symlink() or not artifact.is_file():
        raise ValueError(f"artifact is not a regular file: {artifact}")
    sidecar = metadata_path(artifact)
    checksum = checksum_path(artifact)
    if sidecar.is_symlink() or checksum.is_symlink():
        raise ValueError(f"symlink provenance is not supported: {artifact.name}")
    record = json.loads(sidecar.read_text())
    if record.get("schema_version") != SCHEMA:
        raise ValueError(f"unsupported provenance schema: {artifact.name}")
    required_name = artifact_name(record["version"], record["distro"], record["arch"], record["state"])
    if artifact.name != record["artifact"] or artifact.name != required_name:
        raise ValueError(f"artifact name/provenance mismatch: {artifact.name}")
    if version is not None and record["version"] != version:
        raise ValueError(f"outdated or mixed artifact version: {artifact.name}")
    if record["sha256"] != digest(artifact):
        raise ValueError(f"artifact hash mismatch: {artifact.name}")
    if checksum.read_text() != f'{record["sha256"]}  {artifact.name}\n':
        raise ValueError(f"builder checksum mismatch: {artifact.name}")
    source = record["source"]
    if release and source.get("source_clean") is not True:
        raise ValueError(f"unverified/development source: {artifact.name}")
    if expected is not None and any(source.get(key) != value for key, value in expected.items()):
        raise ValueError(f"source revision/tree/archive mismatch: {artifact.name}")
    if not re.fullmatch(r"[0-9a-f]{64}", source.get("snapshot_sha256", "")):
        raise ValueError(f"missing builder snapshot digest: {artifact.name}")
    if release and record["distro"] == "darwin" and record["state"] != "notarized":
        raise ValueError(f"macOS release artifact is not notarized: {artifact.name}")
    if record["state"] == "notarized":
        signed_input = record.get("signed_input", {})
        signed_name = artifact_name(record["version"], "darwin", "arm64", "signed")
        if (signed_input.get("artifact") != signed_name or
                not re.fullmatch(r"[0-9a-f]{64}", signed_input.get("sha256", "")) or
                not re.fullmatch(r"[0-9a-f]{64}", signed_input.get("metadata_sha256", "")) or
                not record.get("notarized_at_utc")):
            raise ValueError(f"missing signed-input notarization provenance: {artifact.name}")
    return record


def write_record(artifact, record):
    artifact = Path(artifact)
    record["artifact"] = artifact.name
    record["sha256"] = digest(artifact)
    json_write(metadata_path(artifact), record)
    checksum_path(artifact).write_text(f'{record["sha256"]}  {artifact.name}\n')


def record_build(snapshot_file, artifact, distro, arch, state, prefix=None):
    snapshot_data = json.loads(Path(snapshot_file).read_text())
    artifact = Path(artifact)
    if artifact.name != artifact_name(snapshot_data["version"], distro, arch, state):
        raise ValueError("builder output does not have the canonical artifact name")
    record = {
        **snapshot_data,
        "artifact": artifact.name, "distro": distro, "arch": arch, "state": state,
        "built_at_utc": now(),
        "builder": {"os": platform.system(), "arch": platform.machine()},
    }
    if prefix is not None:
        record["prefix"] = prefix
    write_record(artifact, record)


def notarize(pkg, final_pkg, profile, sha256_file=None):
    pkg, final_pkg = Path(pkg).resolve(), Path(final_pkg).resolve()
    record = read_record(pkg, release=False)
    if record["state"] != "signed" or record["source"].get("source_clean") is not True:
        raise ValueError("notarization requires a signed, clean-source builder artifact")
    if final_pkg.name != artifact_name(record["version"], "darwin", "arm64", "notarized"):
        raise ValueError("--final-pkg must use the canonical notarized package name")
    if pkg == final_pkg or final_pkg.exists() or metadata_path(final_pkg).exists() or checksum_path(final_pkg).exists():
        raise ValueError("final package/provenance already exists; use a fresh output directory")
    sha_path = Path(sha256_file).resolve() if sha256_file else None
    if sha_path in (pkg, final_pkg, metadata_path(pkg), metadata_path(final_pkg),
                    checksum_path(pkg), checksum_path(final_pkg)):
        raise ValueError("checksum output must not replace an artifact or provenance file")
    final_pkg.parent.mkdir(parents=True, exist_ok=True)
    work = stage(final_pkg.parent)
    try:
        candidate = work / final_pkg.name
        shutil.copy2(pkg, candidate)
        for command in (
            ["pkgutil", "--check-signature", str(candidate)],
            ["xcrun", "notarytool", "submit", str(candidate), "--keychain-profile", profile, "--wait"],
            ["xcrun", "stapler", "staple", str(candidate)],
            ["xcrun", "stapler", "validate", str(candidate)],
            ["pkgutil", "--check-signature", str(candidate)],
            ["spctl", "--assess", "--type", "install", "-vv", str(candidate)],
        ):
            subprocess.run(command, check=True)
        final_record = {
            **record, "state": "notarized", "notarized_at_utc": now(),
            "signed_input": {"artifact": pkg.name, "sha256": record["sha256"],
                             "metadata_sha256": digest(metadata_path(pkg))},
        }
        write_record(candidate, final_record)
        for path in (candidate, metadata_path(candidate), checksum_path(candidate)):
            shutil.copy2(path, final_pkg.parent / path.name)
        if sha_path:
            sha_path.write_text(checksum_path(final_pkg).read_text())
    finally:
        shutil.rmtree(work)
    print(f"notarized package with final-byte provenance: {final_pkg}")


def package_files(directory):
    return sorted(path for path in Path(directory).iterdir()
                  if path.suffix in (".deb", ".rpm", ".pkg") and not path.name.endswith("-signed.pkg"))


def expected_source(repo, version, revision):
    return source_description(repo, version, revision)[0]


def collect(out_dir, sources, version, revision, clean=False, repo=ROOT, macos_only=False):
    expected = expected_source(repo, version, revision)
    out_dir = Path(out_dir).resolve()
    work = stage(ROOT / "target/package/collection-work")
    try:
        chosen = {}
        if out_dir.exists() and not clean and package_files(out_dir):
            sources = [str(out_dir)] + sources
        for index, source in enumerate(sources):
            if ":" in source:
                # Fetch a complete builder directory; missing paths and transport errors are fatal.
                local = work / f"remote-{index}"
                subprocess.run(["scp", "-q", "-r", "--", source.rstrip("/") + "/.", str(local)], check=True)
            else:
                local = Path(source).resolve()
            if not local.is_dir():
                raise ValueError(f"source directory not found: {source}")
            packages = package_files(local)
            if not packages:
                raise ValueError(f"no final package artifacts in source: {source}")
            for package in packages:
                record = read_record(package, expected, version)
                if macos_only and record["distro"] != "darwin":
                    raise ValueError(f"unexpected Linux artifact in explicit macOS-only collection: {package.name}")
                previous = chosen.get(package.name)
                if previous and (digest(previous) != digest(package) or
                                 metadata_path(previous).read_bytes() != metadata_path(package).read_bytes()):
                    raise ValueError(f"conflicting duplicate artifact: {package.name}")
                chosen[package.name] = package
        if not chosen:
            raise ValueError("no package artifacts collected")
        assembled = work / "assembled"
        assembled.mkdir()
        for package in chosen.values():
            for path in (package, metadata_path(package), checksum_path(package)):
                shutil.copy2(path, assembled / path.name)
        records = [read_record(assembled / name, expected, version) for name in sorted(chosen)]
        index = {
            "schema_version": SCHEMA, "kind": "collection", "version": version,
            "source": expected,
            "collector": {
                "revision": git(repo, "rev-parse", "HEAD"),
                "dirty": bool(git(repo, "status", "--porcelain", "--untracked-files=all")),
            },
            "collected_at_utc": now(),
            "artifacts": [{"artifact": r["artifact"],
                           "metadata_sha256": digest(metadata_path(assembled / r["artifact"]))}
                          for r in records],
        }
        json_write(assembled / "BUILD-METADATA.txt", index)
        for macos, filename in ((False, "SHA256SUMS"), (True, "SHA256SUMS-darwin-arm64")):
            subset = [r for r in records if (r["distro"] == "darwin") == macos]
            if subset:
                (assembled / filename).write_text("".join(f'{r["sha256"]}  {r["artifact"]}\n' for r in subset))
                if macos:
                    json_write(assembled / "BUILD-METADATA-darwin-arm64.txt", index)
        out_dir.mkdir(parents=True, exist_ok=True)
        known_names = {"SHA256SUMS", "SHA256SUMS-darwin-arm64", "BUILD-METADATA.txt", "BUILD-METADATA-darwin-arm64.txt"}
        if clean:
            # Never recursively remove a caller-selected output directory.
            for path in out_dir.iterdir():
                if (path.name in known_names or path.suffix in (".deb", ".rpm", ".pkg") or
                        path.name.endswith((".deb.metadata.json", ".rpm.metadata.json", ".pkg.metadata.json",
                                           ".deb.sha256", ".rpm.sha256", ".pkg.sha256"))):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
        for path in assembled.iterdir():
            destination = out_dir / path.name
            if destination.is_symlink():
                raise ValueError(f"refusing symlink output: {destination}")
            shutil.copy2(path, destination)
        print(f"collected {len(records)} verified builder artifacts: {out_dir}")
    finally:
        shutil.rmtree(work)


def verify(directory, version, revision, require_macos=False, repo=ROOT, platform_checks=True, macos_only=False):
    directory = Path(directory)
    if macos_only and platform_checks and sys.platform != "darwin":
        raise ValueError("macOS-only release verification requires macOS for signature, stapler, and Gatekeeper checks")
    expected = expected_source(repo, version, revision)
    required = set() if macos_only else {artifact_name(version, *target) for target in LINUX_TARGETS}
    mac_name = artifact_name(version, "darwin", "arm64", "notarized")
    if require_macos or macos_only:
        required.add(mac_name)
    found = {p.name for p in package_files(directory)}
    if required - found:
        raise ValueError("missing artifacts: " + ", ".join(sorted(required - found)))
    if found - (required | {mac_name}):
        raise ValueError("unexpected/mixed artifacts: " + ", ".join(sorted(found - (required | {mac_name}))))
    records = [read_record(directory / name, expected, version) for name in sorted(found)]
    index = json.loads((directory / "BUILD-METADATA.txt").read_text())
    expected_entries = [{"artifact": r["artifact"],
                         "metadata_sha256": digest(metadata_path(directory / r["artifact"]))} for r in records]
    if (index.get("schema_version") != SCHEMA or index.get("kind") != "collection" or
            index.get("version") != version or index.get("source") != expected or
            index.get("artifacts") != expected_entries):
        raise ValueError("collection metadata does not match builder provenance")
    for macos, filename in ((False, "SHA256SUMS"), (True, "SHA256SUMS-darwin-arm64")):
        subset = [r for r in records if (r["distro"] == "darwin") == macos]
        if subset:
            wanted = "".join(f'{r["sha256"]}  {r["artifact"]}\n' for r in subset)
            if (directory / filename).read_text() != wanted:
                raise ValueError(f"incomplete or mismatched checksums: {filename}")
    if mac_name in found:
        if json.loads((directory / "BUILD-METADATA-darwin-arm64.txt").read_text()) != index:
            raise ValueError("macOS collection metadata mismatch")
        if platform_checks and sys.platform == "darwin":
            for command in (
                ["xcrun", "stapler", "validate", str(directory / mac_name)],
                ["pkgutil", "--check-signature", str(directory / mac_name)],
                ["spctl", "--assess", "--type", "install", "-vv", str(directory / mac_name)],
            ):
                subprocess.run(command, check=True)
    label = "macOS-only release" if macos_only else "release"
    print(f"{label} artifacts verified: {directory}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    names = sub.add_parser("name")
    names.add_argument("--version", default=VERSION)
    names.add_argument("--distro", required=True)
    names.add_argument("--arch", required=True)
    names.add_argument("--state", default="linux")
    distro = sub.add_parser("distro")
    distro.add_argument("package_type", choices=("deb", "rpm"))
    staging = sub.add_parser("stage")
    staging.add_argument("parent")
    snap = sub.add_parser("snapshot")
    snap.add_argument("--repo", default=str(ROOT))
    snap.add_argument("--version", default=VERSION)
    snap.add_argument("--stage", required=True)
    snap.add_argument("--development", action="store_true")
    record = sub.add_parser("record")
    record.add_argument("--snapshot", required=True)
    record.add_argument("--artifact", required=True)
    record.add_argument("--distro", required=True)
    record.add_argument("--arch", required=True)
    record.add_argument("--state", default="linux")
    record.add_argument("--prefix")
    notary = sub.add_parser("notarize")
    notary.add_argument("--pkg", required=True)
    notary.add_argument("--final-pkg")
    notary.add_argument("--keychain-profile", default="macos-auth-notary")
    notary.add_argument("--sha256-file")
    for command in ("collect", "verify"):
        cmd = sub.add_parser(command)
        cmd.add_argument("--version", default=VERSION)
        cmd.add_argument("--source-commit", default=os.environ.get("SOURCE_COMMIT", "HEAD"))
        if command == "collect":
            cmd.add_argument("--out-dir", default="target/package/release")
            cmd.add_argument("--source", action="append", default=[])
            cmd.add_argument("--clean", action="store_true")
            cmd.add_argument("--macos-only", action="store_true",
                             help="explicit macOS-only staging; reject Linux or unnotarized artifacts")
        else:
            cmd.add_argument("--artifact-dir", default="target/package/release")
            scope = cmd.add_mutually_exclusive_group()
            scope.add_argument("--require-macos", action="store_true",
                               help="require all eight Linux packages plus notarized macOS")
            scope.add_argument("--macos-only", action="store_true",
                               help="explicit macOS-only release; require notarized macOS and reject Linux packages")
    args = parser.parse_args()
    if args.command == "name":
        print(artifact_name(args.version, args.distro, args.arch, args.state))
    elif args.command == "distro":
        print(host_distro(args.package_type))
    elif args.command == "stage":
        print(stage(args.parent))
    elif args.command == "snapshot":
        print(snapshot(args.repo, args.version, args.stage, args.development))
    elif args.command == "record":
        record_build(args.snapshot, args.artifact, args.distro, args.arch, args.state, args.prefix)
    elif args.command == "notarize":
        final = args.final_pkg or str(Path(args.pkg).with_name(Path(args.pkg).name.replace("-signed.pkg", ".pkg")))
        notarize(args.pkg, final, args.keychain_profile, args.sha256_file)
    elif args.command == "collect":
        sources = args.source or os.environ.get("RELEASE_ARTIFACT_SOURCES", "").split()
        collect(args.out_dir, sources, args.version, args.source_commit, args.clean, macos_only=args.macos_only)
    elif args.command == "verify":
        verify(args.artifact_dir, args.version, args.source_commit, args.require_macos, macos_only=args.macos_only)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
