"""Explicit, disposable-container-only integration with real Linux PAM."""

import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LinuxPAMTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macos-auth-e2e-", dir="/root")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.helper = self.base / "helper"
        shutil.copy2(ROOT / "target/debug/macos-auth-helper", self.helper)
        self.helper.chmod(0o700)
        self.vector = json.loads((ROOT / "test-vectors/v1/approval.json").read_text())
        self.host_key = self.base / "host.key"
        self.agent_key = self.base / "agent.key"
        self.agent_pub = self.base / "agent.pub"
        for path, value in (
            (self.host_key, self.vector["host_private_key_hex"]),
            (self.agent_key, self.vector["agent_private_key_hex"]),
            (self.agent_pub, self.vector["agent_public_key_hex"]),
        ):
            path.write_text(value)
            path.chmod(0o600)
        self.socket_path = self.base / "agent.sock"
        self.config = self.base / "config.toml"
        self.config.write_text(
            f'socket_path = "{self.socket_path}"\n'
            f'host_key_file = "{self.host_key}"\n'
            f'agent_pubkey_file = "{self.agent_pub}"\n'
            'host_id = "host-abc"\nhostname = "linux.example.com"\n'
            'timeout_ms = 300\n'
        )
        self.config.chmod(0o600)
        self.service = f"macos-auth-e2e-{os.getpid()}"
        self.pam_file = Path("/etc/pam.d") / self.service
        self.addCleanup(self.pam_file.unlink, missing_ok=True)

    def pam(self, fallback):
        self.pam_file.write_text(
            "auth [success=done authinfo_unavail=ignore default=die] "
            f"{ROOT / 'pam/pam_macos_auth.so'} "
            f"helper={self.helper} conf={self.config} timeout_ms=1500\n"
            f"auth required {fallback}\n"
        )
        return subprocess.run(
            ["pamtester", self.service, "root", "authenticate"],
            capture_output=True, text=True, timeout=5,
        )

    def agent(self, decision):
        process = subprocess.Popen([
            str(self.helper), "fake-agent", "--socket", str(self.socket_path),
            "--host-pubkey-hex", self.vector["host_public_key_hex"],
            "--agent-key-file", str(self.agent_key), "--decision", decision, "--once",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=3)

        self.addCleanup(cleanup)
        for _ in range(100):
            if self.socket_path.exists():
                return process
            if process.poll() is not None:
                self.fail(process.communicate()[1])
            time.sleep(0.01)
        self.fail("fake agent did not start")

    def test_approval_skips_password_module(self):
        self.agent("approved")
        result = self.pam("pam_deny.so")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cancel_continues_to_password_module(self):
        self.agent("cancelled")
        result = self.pam("pam_permit.so")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cancel_does_not_bypass_password_failure(self):
        self.agent("cancelled")
        self.assertNotEqual(self.pam("pam_deny.so").returncode, 0)

    def test_denial_is_not_ignored(self):
        self.agent("denied")
        self.assertNotEqual(self.pam("pam_permit.so").returncode, 0)

    def test_missing_socket_falls_back(self):
        self.assertEqual(self.pam("pam_permit.so").returncode, 0)

    def test_non_root_owned_key_is_not_ignored(self):
        os.chown(self.agent_pub, 1000, 1000)
        self.assertNotEqual(self.pam("pam_permit.so").returncode, 0)

    def test_invalid_signature_is_not_ignored(self):
        self.agent_pub.write_text(self.vector["host_public_key_hex"])
        self.agent("approved")
        self.assertNotEqual(self.pam("pam_permit.so").returncode, 0)

    def peer(self, response):
        ready = threading.Event()
        stop = threading.Event()

        def serve():
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(self.socket_path))
                listener.listen()
                listener.settimeout(3)
                ready.set()
                with listener.accept()[0] as client:
                    client.recv(65536)
                    if response is not None:
                        client.sendall(struct.pack(">I", len(response)) + response)
                    else:
                        stop.wait(timeout=3)

        thread = threading.Thread(target=serve)
        thread.start()

        def cleanup():
            stop.set()
            thread.join(timeout=4)

        self.addCleanup(cleanup)
        self.assertTrue(ready.wait(timeout=3))

    def test_connected_timeout_falls_back(self):
        self.peer(None)
        result = self.pam("pam_permit.so")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_response_is_not_ignored(self):
        self.peer(b"not-json")
        self.assertNotEqual(self.pam("pam_permit.so").returncode, 0)


if __name__ == "__main__":
    if (sys.platform != "linux" or os.geteuid() != 0
            or not Path("/run/.containerenv").is_file()):
        sys.exit("Run this only as root inside a disposable Podman container.")
    unittest.main()
