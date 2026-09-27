import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SSHExamplesTests(unittest.TestCase):
    def test_all_shipped_examples_parse(self):
        for path in (
            "examples/ssh-config",
            "packaging/linux/examples/ssh-config.sample",
            "packaging/macos/examples/ssh-config.sample",
        ):
            with self.subTest(path=path):
                result = subprocess.run(
                    ["ssh", "-G", "-F", str(ROOT / path), "linux-with-macos-auth"],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                forward = next(
                    line for line in result.stdout.splitlines()
                    if line.startswith("remoteforward ")
                )
                self.assertIn("Library/Application Support/macos-auth/agent.sock", forward)


class ReleaseMakefileTests(unittest.TestCase):
    def test_container_target_is_arm64_only(self):
        result = subprocess.run(
            ["make", "-n", "package-arm64-containers"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        )
        self.assertIn("packaging/linux/build-arm64-containers.sh", result.stdout)
        result = subprocess.run(
            ["make", "-n", "package-x86_64-containers"],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_verification_scope_flags_are_exclusive(self):
        for scope in ("", "--macos-only"):
            with self.subTest(scope=scope):
                result = subprocess.run(
                    ["make", "-n", "release-verify", f"RELEASE_SCOPE_FLAGS={scope}",
                     "SOURCE_COMMIT=" + "0" * 40],
                    cwd=ROOT, capture_output=True, text=True, check=True,
                )
                commands = [shlex.split(line) for line in result.stdout.splitlines()
                            if line.startswith("packaging/release/verify-artifacts.sh ")]
                self.assertEqual(len(commands), 1)
                self.assertEqual("--macos-only" in commands[0], bool(scope))
                self.assertEqual("--require-macos" in commands[0], not bool(scope))


class ArchitectureTests(unittest.TestCase):
    def test_container_builds_pin_arm64_for_all_four_images(self):
        with tempfile.TemporaryDirectory(prefix="macos-auth-containers-") as directory:
            base = Path(directory)
            tools = base / "bin"
            tools.mkdir()
            log = base / "podman.jsonl"
            scripts = {
                "uname": 'printf "%s\\n" "$TEST_ARCH"',
                "git": 'case "$1" in rev-parse) printf "%s\\n" "HEAD" ;; esac',
                "sha256sum": "exit 0",
            }
            for name, source in scripts.items():
                tool = tools / name
                tool.write_text("#!/bin/sh\n" + source + "\n")
                tool.chmod(0o700)
            podman = tools / "podman"
            podman.write_text(f"#!{sys.executable}\n" + """
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["PODMAN_LOG"], "a") as output:
    output.write(json.dumps(args) + "\\n")
mount = next(arg for arg in args if arg.endswith(":/out:Z"))
out = pathlib.Path(mount.removesuffix(":/out:Z"))
extension = ".deb" if "ubuntu:" in " ".join(args) else ".rpm"
name = "fixture-" + str(len(list(out.glob("*" + extension)))) + extension
for suffix in ("", ".metadata.json", ".sha256"):
    (out / (name + suffix)).write_text("offline container invocation fixture")
""")
            podman.chmod(0o700)
            for arch in ("arm64", "aarch64"):
                with self.subTest(arch=arch):
                    log.unlink(missing_ok=True)
                    work = base / f"work-{arch}"
                    result = subprocess.run(
                        ["sh", "packaging/linux/build-arm64-containers.sh"], cwd=ROOT,
                        capture_output=True, text=True, env={
                            **os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                            "PODMAN": str(podman), "PODMAN_LOG": str(log),
                            "TEST_ARCH": arch, "OUT_DIR": str(base / f"out-{arch}"),
                            "WORK_DIR": str(work),
                        },
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    calls = [json.loads(line) for line in log.read_text().splitlines()]
                    images = (
                        "docker.io/library/ubuntu:24.04", "docker.io/library/ubuntu:25.10",
                        "registry.access.redhat.com/ubi9/ubi:9.7",
                        "registry.access.redhat.com/ubi10/ubi:10.1",
                    )
                    self.assertEqual(len(calls), len(images))
                    for call, image in zip(calls, images):
                        self.assertEqual(call[:4], ["run", "--rm", "--platform", "linux/arm64"])
                        self.assertIn(image, call)
                    self.assertEqual(list(work.iterdir()), [])

    def test_linux_builders_and_installer_reject_unsupported_hosts(self):
        with tempfile.TemporaryDirectory(prefix="macos-auth-arch-") as directory:
            base = Path(directory)
            uname = base / "uname"
            uname.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_ARCH"\n')
            uname.chmod(0o700)
            env = {**os.environ, "PATH": f"{base}:{os.environ['PATH']}"}
            commands = (
                ["packaging/linux/build-deb.sh"],
                ["packaging/linux/build-rpm.sh"],
                ["packaging/linux/build-arm64-containers.sh"],
                ["scripts/linux-install-dev.sh", "--dev-dir", str(base)],
            )
            for arch in ("x86_64", "amd64", "armv7l"):
                for command in commands:
                    with self.subTest(arch=arch, command=command):
                        result = subprocess.run(
                            ["sh", *command], cwd=ROOT, env={**env, "TEST_ARCH": arch},
                            capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertIn("arm64/aarch64", result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS cross-compilers")
    def test_swift_and_pam_reject_x86_64_targets(self):
        commands = (
            ["swiftc", "-typecheck", "-target", "x86_64-apple-macosx13.0",
             *map(str, sorted((ROOT / "agent/Sources/MacosAuthAgent").glob("*.swift")))],
            ["cc", "-arch", "x86_64", "-fsyntax-only", "pam/pam_macos_auth.c"],
        )
        for command in commands:
            with self.subTest(compiler=command[0]):
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("macos-auth supports only arm64/aarch64 build targets", result.stderr)


@unittest.skipUnless(sys.platform == "darwin", "requires macOS plutil")
class LaunchAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macos-auth-setup-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.log = self.base / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        CALL_LOG=str(self.log))
        self.fixture = self.base / "R&D <agent> \\ paths"
        self.fixture.mkdir()
        self.agent = self.fixture / "agent"
        self.agent.write_text("#!/bin/sh\nexit 0\n")
        self.agent.chmod(0o700)
        self.config = self.fixture / "config.json"
        self.config.write_text("{}")
        self.plist = self.fixture / "agent.plist"
        self.logs = self.fixture / "logs"
        self.write_tool("launchctl", """
import json, os, sys
with open(os.environ["CALL_LOG"], "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "print":
    sys.exit(0 if os.environ.get("LOADED") == "1" else 1)
if sys.argv[1] == "bootout" and os.environ.get("FAIL_BOOTOUT") == "1":
    sys.exit(1)
""")
        self.write_tool("plutil", """
import os, subprocess, sys
if os.environ.get("INVALID_PLIST") == "1" and sys.argv[1] == "-lint":
    sys.exit(1)
sys.exit(subprocess.run(["/usr/bin/plutil", *sys.argv[1:]]).returncode)
""")

    def write_tool(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o700)

    def install(self, *extra):
        return subprocess.run(
            ["sh", str(ROOT / "scripts/install-launchagent.sh"),
             "--agent-bin", str(self.agent), "--config", str(self.config),
             "--plist", str(self.plist), "--log-dir", str(self.logs), *extra],
            env=self.env, capture_output=True, text=True,
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_paths_round_trip_without_xml_or_sed_interpretation(self):
        self.env["LOADED"] = "1"
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(data["ProgramArguments"],
                         [str(self.agent), "serve", "--config", str(self.config)])
        self.assertEqual(data["StandardOutPath"], str(self.logs / "agent.stdout.log"))
        self.assertEqual(data["StandardErrorPath"], str(self.logs / "agent.stderr.log"))
        self.assertEqual([call[0] for call in self.calls()],
                         ["print", "bootout", "bootstrap", "enable"])
        self.assertEqual(list(self.fixture.glob("*.tmp.*")), [])

    def test_invalid_plist_never_stops_existing_agent(self):
        self.plist.write_text("existing plist")
        self.env["INVALID_PLIST"] = "1"
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.plist.read_text(), "existing plist")
        self.assertEqual(self.calls(), [])
        self.assertEqual(list(self.fixture.glob("*.tmp.*")), [])

    def test_failed_bootout_preserves_existing_plist(self):
        self.plist.write_text("existing plist")
        self.env.update(LOADED="1", FAIL_BOOTOUT="1")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.plist.read_text(), "existing plist")
        self.assertEqual([call[0] for call in self.calls()], ["print", "bootout"])

    def test_rejects_symlink_without_touching_target(self):
        target = self.fixture / "original"
        target.write_text("keep")
        self.plist.symlink_to(target)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "keep")
        self.assertEqual(self.calls(), [])

    def test_rejects_missing_option_value(self):
        result = self.install("--config")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Missing value", result.stderr)


if __name__ == "__main__":
    unittest.main()
