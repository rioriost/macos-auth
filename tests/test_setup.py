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
