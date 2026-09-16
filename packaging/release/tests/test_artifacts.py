"""Offline protocol tests. Synthetic package bytes are NOT real package validation."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import unittest
from unittest import mock
import uuid

RELEASE = Path(__file__).resolve().parents[1]
ROOT = RELEASE.parents[1]
sys.path.insert(0, str(RELEASE))
import artifacts
import upload_draft

VERSION = "0.1.2"
SOURCE = {
    "source_commit": "a" * 40, "source_tree": "b" * 40,
    "source_archive_sha256": "c" * 64, "source_clean": True,
}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / "target/release-tests" / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.directory)
        output = contextlib.redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)
        self.output = self.directory / "release with spaces"
        self.builder = self.directory / "builder"
        self.builder.mkdir()
        self.snapshot_file = self.directory / "source.json"
        artifacts.json_write(self.snapshot_file, {
            "schema_version": 1, "version": VERSION,
            "source": {**SOURCE, "snapshot_sha256": "d" * 64},
        })
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(artifacts, "expected_source", return_value=SOURCE).start()
        mock.patch.object(artifacts, "git", side_effect=lambda repo, *args: "" if args[0] == "status" else "e" * 40).start()

    def package(self, distro="ubuntu24.04", arch="arm64", state="linux", directory=None):
        directory = directory or self.builder
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / artifacts.artifact_name(VERSION, distro, arch, state)
        path.write_bytes(b"synthetic offline fixture: " + path.name.encode())
        artifacts.record_build(self.snapshot_file, path, distro, arch, state)
        return path

    def matrix(self, macos=True):
        for distro, arch in artifacts.LINUX_TARGETS:
            self.package(distro, arch)
        if macos:
            signed = self.package("darwin", "arm64", "signed")
            final = self.builder / artifacts.artifact_name(VERSION, "darwin", "arm64", "notarized")
            with mock.patch.object(artifacts.subprocess, "run", side_effect=self.apple_mock):
                artifacts.notarize(signed, final, "offline-profile")

    @staticmethod
    def apple_mock(command, **kwargs):
        if command[:3] == ["xcrun", "stapler", "staple"]:
            with Path(command[3]).open("ab") as stream:
                stream.write(b":synthetic-stapled-ticket")
        return subprocess.CompletedProcess(command, 0)

    def collect(self, sources=None, clean=False, macos_only=False):
        artifacts.collect(self.output, sources or [str(self.builder)], VERSION, SOURCE["source_commit"],
                          clean, macos_only=macos_only)

    def verify(self, require_macos=True, macos_only=False):
        artifacts.verify(self.output, VERSION, SOURCE["source_commit"], require_macos,
                         platform_checks=False, macos_only=macos_only)

    def notarized_package(self):
        signed = self.package("darwin", "arm64", "signed")
        final = self.builder / artifacts.artifact_name(VERSION, "darwin", "arm64", "notarized")
        with mock.patch.object(artifacts.subprocess, "run", side_effect=self.apple_mock):
            artifacts.notarize(signed, final, "offline-profile")
        return final


class ArtifactTests(Fixture):
    def test_all_eight_names_are_distinct(self):
        names = {artifacts.artifact_name(VERSION, *target) for target in artifacts.LINUX_TARGETS}
        self.assertEqual(len(names), 8)
        self.assertIn("macos-auth_0.1.2_ubuntu24.04_arm64.deb", names)
        self.assertIn("macos-auth_0.1.2_ubuntu25.10_arm64.deb", names)
        self.assertIn("macos-auth-0.1.2-1.rhel9.aarch64.rpm", names)
        self.assertIn("macos-auth-0.1.2-1.rhel10.x86_64.rpm", names)
        with self.assertRaisesRegex(ValueError, "unsupported"):
            artifacts.artifact_name(VERSION, "debian12", "amd64")

    def test_native_os_detection(self):
        for package, os_release, expected in (
            ("deb", 'ID=ubuntu\nVERSION_ID="24.04"', "ubuntu24.04"),
            ("deb", 'ID=ubuntu\nVERSION_ID="25.10"', "ubuntu25.10"),
            ("rpm", 'ID=rhel\nVERSION_ID="9.7"', "rhel9"),
            ("rpm", 'ID=rocky\nVERSION_ID="10.1"', "rhel10"),
        ):
            with self.subTest(expected=expected), mock.patch.object(Path, "read_text", return_value=os_release):
                self.assertEqual(artifacts.host_distro(package), expected)
        with mock.patch.object(Path, "read_text", return_value="ID=fedora\nVERSION_ID=43"):
            with self.assertRaisesRegex(ValueError, "unsupported"):
                artifacts.host_distro("rpm")

    def test_full_matrix_preserves_builder_metadata_and_collector_identity(self):
        self.matrix()
        self.collect()
        self.verify()
        for package in artifacts.package_files(self.builder):
            self.assertEqual(artifacts.metadata_path(package).read_bytes(),
                             artifacts.metadata_path(self.output / package.name).read_bytes())
            self.assertEqual(artifacts.checksum_path(package).read_bytes(),
                             artifacts.checksum_path(self.output / package.name).read_bytes())
        index = json.loads((self.output / "BUILD-METADATA.txt").read_text())
        self.assertEqual(index["source"]["source_commit"], "a" * 40)
        self.assertEqual(index["collector"]["revision"], "e" * 40)

    def test_conflicting_duplicate_rejected_before_output_changes(self):
        package = self.package()
        other = self.directory / "other"
        duplicate = self.package(directory=other)
        duplicate.write_bytes(b"other valid builder bytes")
        artifacts.record_build(self.snapshot_file, duplicate, "ubuntu24.04", "arm64", "linux")
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "conflicting duplicate"):
            self.collect([str(self.builder), str(other)], clean=True)
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertFalse((self.output / package.name).exists())

    def test_same_bytes_different_builder_metadata_rejected(self):
        package = self.package()
        other = self.directory / "other"
        other.mkdir()
        for path in (package, artifacts.metadata_path(package), artifacts.checksum_path(package)):
            shutil.copy2(path, other / path.name)
        record = json.loads(artifacts.metadata_path(other / package.name).read_text())
        record["built_at_utc"] = "different builder"
        artifacts.json_write(artifacts.metadata_path(other / package.name), record)
        with self.assertRaisesRegex(ValueError, "conflicting duplicate"):
            self.collect([str(self.builder), str(other)])

    def test_identical_duplicate_is_idempotent(self):
        self.package()
        self.collect([str(self.builder), str(self.builder)])
        self.collect()

    def test_missing_metadata_or_builder_checksum_rejected(self):
        package = self.package()
        artifacts.metadata_path(package).unlink()
        with self.assertRaises(FileNotFoundError):
            self.collect()
        artifacts.record_build(self.snapshot_file, package, "ubuntu24.04", "arm64", "linux")
        artifacts.checksum_path(package).unlink()
        with self.assertRaises(FileNotFoundError):
            self.collect()

    def test_wrong_source_or_version_or_dirty_provenance_rejected(self):
        package = self.package()
        original = json.loads(artifacts.metadata_path(package).read_text())
        mutations = [
            ("version", "0.1.1"), ("source_commit", "f" * 40),
            ("source_tree", "f" * 40), ("source_archive_sha256", "f" * 64),
            ("source_clean", False),
        ]
        for key, value in mutations:
            with self.subTest(key=key):
                record = json.loads(json.dumps(original))
                if key == "version":
                    record[key] = value
                else:
                    record["source"][key] = value
                artifacts.json_write(artifacts.metadata_path(package), record)
                with self.assertRaises(ValueError):
                    self.collect()

    def test_tampered_bytes_rejected_at_collection_and_verification(self):
        self.matrix()
        self.collect()
        package = artifacts.package_files(self.builder)[0]
        package.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.collect(clean=True)
        output_package = self.output / package.name
        output_package.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.verify()

    def test_checksums_must_cover_every_artifact(self):
        self.matrix()
        self.collect()
        (self.output / "SHA256SUMS").write_text("")
        with self.assertRaisesRegex(ValueError, "checksums"):
            self.verify()

    def test_all_eight_linux_and_macos_gates_remain_required(self):
        self.matrix(macos=False)
        self.collect()
        self.verify(require_macos=False)
        with self.assertRaisesRegex(ValueError, "missing artifacts"):
            self.verify()
        package = artifacts.package_files(self.output)[0]
        package.unlink()
        with self.assertRaisesRegex(ValueError, "missing artifacts"):
            self.verify(require_macos=False)

    def test_unsigned_macos_rejected_even_when_macos_is_optional(self):
        self.matrix(macos=False)
        self.package("darwin", "arm64", "unsigned")
        with self.assertRaisesRegex(ValueError, "not notarized"):
            self.collect()

    def test_explicit_macos_only_requires_provenance_and_has_no_linux_fallback(self):
        package = self.notarized_package()
        self.collect(macos_only=True)
        self.verify(macos_only=True)
        with self.assertRaisesRegex(ValueError, "missing artifacts"):
            self.verify()
        artifacts.metadata_path(self.output / package.name).unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify(macos_only=True)

    def test_macos_only_rejects_linux_artifacts(self):
        self.notarized_package()
        self.package()
        self.collect()
        with self.assertRaisesRegex(ValueError, "unexpected/mixed"):
            self.verify(macos_only=True)

    def test_macos_only_collection_rejects_mixed_scope_before_changes(self):
        self.notarized_package()
        self.package()
        self.output.mkdir()
        (self.output / "keep.txt").write_text("keep")
        with self.assertRaisesRegex(ValueError, "unexpected Linux artifact"):
            self.collect(clean=True, macos_only=True)
        self.assertEqual({path.name for path in self.output.iterdir()}, {"keep.txt"})

    def test_macos_only_collection_rejects_unsigned_or_dirty_packages(self):
        package = self.package("darwin", "arm64", "unsigned")
        with self.assertRaisesRegex(ValueError, "not notarized"):
            self.collect(macos_only=True)
        for path in (package, artifacts.metadata_path(package), artifacts.checksum_path(package)):
            path.unlink()
        final = self.notarized_package()
        record = json.loads(artifacts.metadata_path(final).read_text())
        record["source"]["source_clean"] = False
        artifacts.json_write(artifacts.metadata_path(final), record)
        with self.assertRaisesRegex(ValueError, "development source"):
            self.collect(macos_only=True)

    def test_notarized_metadata_requires_signed_input_chain(self):
        final = self.notarized_package()
        record = json.loads(artifacts.metadata_path(final).read_text())
        del record["signed_input"]
        artifacts.json_write(artifacts.metadata_path(final), record)
        with self.assertRaisesRegex(ValueError, "signed-input"):
            self.collect(macos_only=True)

    def test_macos_only_runs_all_apple_validation_commands_on_macos(self):
        self.notarized_package()
        self.collect()
        with mock.patch.object(artifacts.sys, "platform", "darwin"), \
             mock.patch.object(artifacts.subprocess, "run", side_effect=self.apple_mock) as commands:
            artifacts.verify(self.output, VERSION, SOURCE["source_commit"], macos_only=True)
        self.assertEqual([call.args[0][:2] for call in commands.call_args_list], [
            ["xcrun", "stapler"], ["pkgutil", "--check-signature"], ["spctl", "--assess"],
        ])

    def test_macos_only_rejects_platform_validation_failure(self):
        self.notarized_package()
        self.collect()
        with mock.patch.object(artifacts.sys, "platform", "darwin"), \
             mock.patch.object(artifacts.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "spctl")):
            with self.assertRaises(subprocess.CalledProcessError):
                artifacts.verify(self.output, VERSION, SOURCE["source_commit"], macos_only=True)

    def test_macos_only_cannot_skip_apple_verification_on_linux(self):
        with mock.patch.object(artifacts.sys, "platform", "linux"):
            with self.assertRaisesRegex(ValueError, "requires macOS"):
                artifacts.verify(self.output, VERSION, SOURCE["source_commit"], macos_only=True)

    def test_notes_scope_is_explicit_and_default_still_lists_all_targets(self):
        notes = self.directory / "notes.md"
        env = {**os.environ, "VERSION": VERSION, "SOURCE_COMMIT": SOURCE["source_commit"], "OUT_FILE": str(notes)}
        subprocess.run(["sh", str(RELEASE / "make-notes.sh")], env={**env, "RELEASE_SCOPE": "macos-only"},
                       text=True, capture_output=True, check=True)
        self.assertIn("No Linux binary packages are included", notes.read_text())
        self.assertNotIn("ubuntu24.04", notes.read_text())
        subprocess.run(["sh", str(RELEASE / "make-notes.sh")], env={**env, "RELEASE_SCOPE": "full"},
                       text=True, capture_output=True, check=True)
        self.assertIn("ubuntu24.04_arm64.deb", notes.read_text())
        self.assertIn("rhel10.x86_64.rpm", notes.read_text())

    def test_old_native_basename_is_not_silently_accepted(self):
        package = self.package()
        package.rename(package.parent / "macos-auth_0.1.2_arm64.deb")
        with self.assertRaises(FileNotFoundError):
            self.collect()

    def test_clean_only_removes_known_artifact_outputs(self):
        self.package()
        self.output.mkdir()
        (self.output / "unrelated").mkdir()
        (self.output / "unrelated/precious.txt").write_text("keep")
        (self.output / "RELEASE-NOTES.md").write_text("manual validation")
        self.collect(clean=True)
        self.assertEqual((self.output / "unrelated/precious.txt").read_text(), "keep")
        self.assertEqual((self.output / "RELEASE-NOTES.md").read_text(), "manual validation")

    def test_existing_notes_only_directory_can_be_collected_without_clean(self):
        self.package()
        self.output.mkdir()
        (self.output / "RELEASE-NOTES.md").write_text("manual validation")
        self.collect()
        self.assertEqual((self.output / "RELEASE-NOTES.md").read_text(), "manual validation")

    def test_remote_errors_are_not_ignored(self):
        with mock.patch.object(artifacts.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "scp")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.collect(["builder:/missing"])
        self.assertFalse(self.output.exists())

    def test_notarization_preserves_signed_input_and_hashes_final_bytes(self):
        signed = self.package("darwin", "arm64", "signed")
        original_bytes = signed.read_bytes()
        original_metadata = artifacts.metadata_path(signed).read_bytes()
        final = self.builder / artifacts.artifact_name(VERSION, "darwin", "arm64", "notarized")
        checksum = self.builder / "SHA256SUMS.cask"
        with mock.patch.object(artifacts.subprocess, "run", side_effect=self.apple_mock) as commands:
            artifacts.notarize(signed, final, "offline", checksum)
        self.assertEqual(signed.read_bytes(), original_bytes)
        self.assertEqual(artifacts.metadata_path(signed).read_bytes(), original_metadata)
        record = artifacts.read_record(final, SOURCE, VERSION)
        self.assertEqual(record["state"], "notarized")
        self.assertEqual(record["signed_input"]["sha256"], hashlib.sha256(original_bytes).hexdigest())
        self.assertEqual(record["signed_input"]["metadata_sha256"], hashlib.sha256(original_metadata).hexdigest())
        self.assertNotEqual(record["sha256"], record["signed_input"]["sha256"])
        self.assertEqual(checksum.read_text(), artifacts.checksum_path(final).read_text())
        self.assertEqual(commands.call_count, 6)
        self.collect()

    def test_notary_failure_does_not_publish_or_mutate_input(self):
        signed = self.package("darwin", "arm64", "signed")
        original = signed.read_bytes()
        final = self.builder / artifacts.artifact_name(VERSION, "darwin", "arm64", "notarized")
        with mock.patch.object(artifacts.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "xcrun")):
            with self.assertRaises(subprocess.CalledProcessError):
                artifacts.notarize(signed, final, "offline")
        self.assertEqual(signed.read_bytes(), original)
        self.assertFalse(final.exists())
        self.assertFalse(list(self.builder.glob(".macos-auth-stage-*")))

    def test_notary_rejects_wrong_final_name_and_overwrite(self):
        signed = self.package("darwin", "arm64", "signed")
        final = self.builder / artifacts.artifact_name(VERSION, "darwin", "arm64", "notarized")
        with mock.patch.object(artifacts.subprocess, "run") as commands:
            with self.assertRaisesRegex(ValueError, "canonical"):
                artifacts.notarize(signed, self.builder / "wrong.pkg", "offline")
            with self.assertRaisesRegex(ValueError, "checksum output"):
                artifacts.notarize(signed, final, "offline", signed)
            final.write_bytes(b"keep")
            with self.assertRaisesRegex(ValueError, "already exists"):
                artifacts.notarize(signed, final, "offline")
            commands.assert_not_called()
        self.assertEqual(final.read_bytes(), b"keep")

    def test_snapshot_fails_closed_for_dirty_source(self):
        with mock.patch.object(artifacts, "git", return_value=" M tracked-source"):
            with self.assertRaisesRegex(ValueError, "clean committed"):
                artifacts.snapshot(ROOT, VERSION, self.directory)
        self.assertFalse((self.directory / "source").exists())

    def test_committed_version_must_match_requested_version(self):
        def git_response(repo, *args):
            return 'version = "0.1.1"' if args[0] == "show" else "a" * 40
        with mock.patch.object(artifacts, "git", side_effect=git_response):
            with self.assertRaisesRegex(ValueError, "committed helper manifest"):
                artifacts.source_description(ROOT, VERSION)

    def test_snapshot_uses_committed_archive_not_ignored_build_outputs(self):
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w") as archive:
            info = tarfile.TarInfo("source.txt")
            content = b"committed input"
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
        with mock.patch.object(artifacts, "source_description", return_value=(dict(SOURCE), payload.getvalue())):
            source = artifacts.snapshot(ROOT, VERSION, self.directory)
        self.assertEqual((source / "source.txt").read_bytes(), b"committed input")
        self.assertFalse((source / "target").exists())
        record = json.loads((self.directory / "source.json").read_text())
        self.assertTrue(record["source"]["source_clean"])
        self.assertEqual(len(record["source"]["snapshot_sha256"]), 64)

    def test_development_snapshot_records_dirty_version_but_cannot_be_released(self):
        repo = self.directory / "development"
        (repo / "crates/helper").mkdir(parents=True)
        (repo / "crates/helper/Cargo.toml").write_text('version = "0.1.2"\n')
        (repo / "new-source.txt").write_text("uncommitted development input")
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w"):
            pass
        with mock.patch.object(artifacts, "source_description", return_value=(dict(SOURCE), payload.getvalue())), \
             mock.patch.object(artifacts, "run", return_value=b"crates/helper/Cargo.toml\0new-source.txt\0"), \
             mock.patch.object(artifacts, "git", return_value=" M crates/helper/Cargo.toml"):
            source = artifacts.snapshot(repo, VERSION, self.directory, development=True)
        self.assertEqual((source / "new-source.txt").read_text(), "uncommitted development input")
        record = json.loads(self.snapshot_file.read_text())
        self.assertFalse(record["source"]["source_clean"])
        self.assertIsNone(record["source"]["source_archive_sha256"])
        package = self.package("darwin", "arm64", "unsigned")
        with self.assertRaisesRegex(ValueError, "development source"):
            artifacts.read_record(package, SOURCE, VERSION)

    def test_macos_skip_build_cannot_delete_caller_directory(self):
        out = self.directory / "precious-output"
        out.mkdir()
        sentinel = out / "keep.txt"
        sentinel.write_text("keep")
        result = subprocess.run([
            "sh", str(ROOT / "packaging/macos/build-pkg.sh"),
            "--out-dir", str(out), "--skip-build",
        ], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot prove source provenance", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_macos_builder_never_deletes_caller_directory_on_dirty_source(self):
        out = self.directory / "precious-output"
        out.mkdir()
        sentinel = out / "keep.txt"
        sentinel.write_text("keep")
        fake_bin = self.directory / "mac-tools"
        fake_bin.mkdir()
        # The dirty guard must run before any compiler/package tool is invoked.
        for command in ("swift", "pkgbuild", "productbuild"):
            tool = fake_bin / command
            tool.write_text("#!/bin/sh\nexit 91\n")
            tool.chmod(0o755)
        (fake_bin / "uname").write_text("#!/bin/sh\nprintf 'arm64\\n'\n")
        (fake_bin / "uname").chmod(0o755)
        (fake_bin / "git").write_text("#!/bin/sh\nprintf ' M dirty-file\\n'\n")
        (fake_bin / "git").chmod(0o755)
        environment = {**os.environ, "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"]}
        environment.pop("CODESIGN_IDENTITY", None)
        environment.pop("PKG_SIGN_IDENTITY", None)
        result = subprocess.run([
            "sh", str(ROOT / "packaging/macos/build-pkg.sh"), "--out-dir", str(out),
        ], text=True, capture_output=True, env=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean committed source", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertEqual({path.name for path in out.iterdir()}, {"keep.txt"})


GH_MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
state_file = pathlib.Path(os.environ["MOCK_GH_STATE"])
state = json.loads(state_file.read_text())
args = sys.argv[1:]
with open(os.environ["MOCK_GH_LOG"], "a") as output:
    output.write(json.dumps(args) + "\n")
if args[:2] == ["release", "view"]:
    if state["mode"] in ("missing", "error", "view-error-existing"):
        sys.exit(1)
    if "--json" in args:
        print(json.dumps({"isDraft": state["mode"] == "draft"}))
elif args[:1] == ["api"]:
    if state["mode"] == "error":
        sys.exit(1)
    print(json.dumps([[{"tag_name": "v0.1.2"}]] if state["mode"] == "view-error-existing" else [[]]))
elif args[:2] == ["release", "create"]:
    state["mode"] = "draft"
    state_file.write_text(json.dumps(state))
elif args[:2] in (["release", "edit"], ["release", "upload"]):
    if state.get("publish_after_edit") and args[1] == "edit":
        state["mode"] = "published"
        state_file.write_text(json.dumps(state))
else:
    sys.exit(90)
'''


class UploadTests(Fixture):
    def setUp(self):
        super().setUp()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(GH_MOCK)
        gh.chmod(0o755)
        self.state = self.directory / "gh-state.json"
        self.log = self.directory / "gh-calls.jsonl"
        self.notes = self.directory / "release notes.md"
        self.notes.write_text("synthetic offline test only")
        mock.patch.dict(os.environ, {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "MOCK_GH_STATE": str(self.state), "MOCK_GH_LOG": str(self.log),
        }).start()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def invoke(self, mode, publish_after_edit=False, real_verify=True, macos_only=False):
        artifacts.json_write(self.state, {"mode": mode, "publish_after_edit": publish_after_edit})
        self.output.mkdir(exist_ok=True)
        argv = [
            "upload-draft", "--repo", "offline/repo", "--tag", "v0.1.2",
            "--target", "a" * 40, "--title", "offline fixture",
            "--notes-file", str(self.notes), "--artifact-dir", str(self.output),
        ]
        if macos_only:
            argv.append("--macos-only")
        actual_verify = artifacts.verify
        def offline_verify(*args, **kwargs):
            kwargs["platform_checks"] = False
            return actual_verify(*args, **kwargs)
        with mock.patch.object(sys, "argv", argv), mock.patch.object(
                artifacts, "verify", side_effect=offline_verify if real_verify else None):
            upload_draft.main()

    def assert_no_mutations(self):
        self.assertFalse(any(call[:2] in (
            ["release", "create"], ["release", "edit"], ["release", "upload"],
        ) for call in self.calls()))

    def test_published_release_never_mutated(self):
        with self.assertRaisesRegex(ValueError, "published"):
            self.invoke("published")
        self.assert_no_mutations()
        self.assertIn("isDraft", self.calls()[0])

    def test_query_failure_is_not_treated_as_missing(self):
        with self.assertRaisesRegex(ValueError, "query failed"):
            self.invoke("error")
        self.assert_no_mutations()

    def test_failed_view_with_existing_listing_refuses(self):
        with self.assertRaisesRegex(ValueError, "draft-state query failed"):
            self.invoke("view-error-existing")
        self.assert_no_mutations()

    def test_missing_release_creates_only_draft_with_full_gate(self):
        self.matrix()
        self.collect()
        self.invoke("missing")
        calls = self.calls()
        creation = next(call for call in calls if call[:2] == ["release", "create"])
        self.assertIn("--draft", creation)
        upload = next(call for call in calls if call[:2] == ["release", "upload"])
        self.assertTrue(any("release with spaces/" in part and part.endswith(".metadata.json") for part in upload))
        self.assertFalse(any(call[:2] == ["release", "edit"] for call in calls))

    def test_existing_draft_can_update(self):
        self.matrix()
        self.collect()
        self.invoke("draft")
        calls = self.calls()
        self.assertTrue(any(call[:2] == ["release", "edit"] for call in calls))
        self.assertTrue(any(call[:2] == ["release", "upload"] for call in calls))
        self.assertFalse(any(call[:2] == ["release", "create"] for call in calls))

    def test_incomplete_artifacts_block_create(self):
        self.package()
        self.collect()
        with self.assertRaisesRegex(ValueError, "missing artifacts"):
            self.invoke("missing")
        self.assert_no_mutations()

    def test_explicit_macos_only_draft_upload_includes_only_verified_macos_assets(self):
        self.notarized_package()
        self.collect(macos_only=True)
        self.invoke("missing", macos_only=True)
        upload = next(call for call in self.calls() if call[:2] == ["release", "upload"])
        self.assertIn(str(self.output / "SHA256SUMS-darwin-arm64"), upload)
        self.assertNotIn(str(self.output / "SHA256SUMS"), upload)
        self.assertTrue(any(part.endswith(".pkg.metadata.json") for part in upload))
        self.assertTrue(any(part.endswith(".pkg.sha256") for part in upload))

    def test_macos_only_never_implicitly_replaces_full_draft_gate(self):
        self.notarized_package()
        self.collect()
        with self.assertRaisesRegex(ValueError, "missing artifacts"):
            self.invoke("missing")
        self.assert_no_mutations()

    def test_macos_only_does_not_bypass_published_guard(self):
        with self.assertRaisesRegex(ValueError, "published"):
            self.invoke("published", macos_only=True)
        self.assert_no_mutations()

    def test_macos_only_upload_rejects_mixed_scope_before_mutation(self):
        self.notarized_package()
        self.package()
        self.collect()
        with self.assertRaisesRegex(ValueError, "unexpected/mixed"):
            self.invoke("missing", macos_only=True)
        self.assert_no_mutations()

    def test_published_between_edit_and_upload_blocks_upload(self):
        self.matrix()
        self.collect()
        with self.assertRaisesRegex(ValueError, "published"):
            self.invoke("draft", publish_after_edit=True)
        self.assertFalse(any(call[:2] == ["release", "upload"] for call in self.calls()))

    def test_shell_entrypoint_published_guard(self):
        artifacts.json_write(self.state, {"mode": "published"})
        self.output.mkdir()
        result = subprocess.run([
            "sh", str(RELEASE / "upload-draft.sh"), "--repo", "offline/repo", "--tag", "v0.1.2",
            "--target", "a" * 40, "--title", "offline", "--notes-file", str(self.notes),
            "--artifact-dir", str(self.output),
        ], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("published", result.stderr)
        self.assert_no_mutations()


if __name__ == "__main__":
    unittest.main()
