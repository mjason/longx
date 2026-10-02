"""Bootstrap regression tests: no real downloads, installs, or platform changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install-macos.sh"


class MacBootstrapTest(unittest.TestCase):
    def run_script(self, *args, platform="Darwin", arch="arm64", uid="501",
                   download_status="0", python_status="0", install_status="0"):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            mocks = root / "bin"
            mocks.mkdir()
            log = root / "calls"
            commands = {
                "uname": 'case "$1" in -s) echo "$TEST_PLATFORM";; -m) echo "$TEST_ARCH";; esac',
                "id": 'echo "$TEST_UID"',
                "python3": '''
if [ "$1" = -c ]; then exit "$TEST_PYTHON_STATUS"; fi
printf '%s\\n' "$@" >> "$TEST_LOG"
exit "$TEST_INSTALL_STATUS"
''',
                "curl": '''
printf '%s\\n' "curl $*" >> "$TEST_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then shift; printf 'downloaded payload' > "$1"; fi
  shift
done
exit "$TEST_DOWNLOAD_STATUS"
''',
            }
            for name, body in commands.items():
                path = mocks / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o700)
            env = {
                **os.environ, "PATH": str(mocks) + os.pathsep + os.environ["PATH"],
                "TMPDIR": str(root), "TEST_LOG": str(log),
                "TEST_PLATFORM": platform, "TEST_ARCH": arch, "TEST_UID": uid,
                "TEST_DOWNLOAD_STATUS": download_status, "TEST_PYTHON_STATUS": python_status,
                "TEST_INSTALL_STATUS": install_status,
            }
            result = subprocess.run(["sh", str(SCRIPT), *args], env=env,
                                    capture_output=True, text=True)
            calls = log.read_text() if log.exists() else ""
            self.assertEqual(list(root.glob("longx-installer.*")), [], "temporary installer was not cleaned")
            return result, calls

    def test_forwards_arguments_and_enforces_https(self):
        result, calls = self.run_script("0.2.106", "--tarball", "/path with spaces/archive.tar.gz", "--no-service")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--proto =https --proto-redir =https", calls)
        self.assertIn("https://github.com/mjason/longx/releases/latest/download/install-macos.py", calls)
        self.assertIn("\n0.2.106\n--tarball\n/path with spaces/archive.tar.gz\n--no-service\n", calls)

    def test_refuses_wrong_platform_rosetta_root_and_old_python_before_download(self):
        for options in [{"platform": "Linux"}, {"arch": "x86_64"}, {"uid": "0"}, {"python_status": "1"}]:
            with self.subTest(options=options):
                result, calls = self.run_script(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, "")

    def test_failed_partial_download_is_not_executed(self):
        result, calls = self.run_script(download_status="18")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("\n", calls.rstrip("\n"))
        self.assertIn("尚未执行安装", result.stderr)

    def test_installer_failure_is_propagated_and_cleaned(self):
        result, _ = self.run_script(install_status="7")
        self.assertEqual(result.returncode, 7)

    def test_help_does_not_download_or_require_mac(self):
        result, calls = self.run_script("--help", platform="Linux")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assertEqual(calls, "")
