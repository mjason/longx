"""Installer regressions: no real downloads, services or cgroups are changed."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tarfile
import tempfile
import termios
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
SOURCE = SCRIPT.read_text()
FUNCTIONS = SOURCE[SOURCE.index("say() {"):SOURCE.index("service_active() {")]


class LinuxCgroupInstallerTest(unittest.TestCase):
    def run_selection(self, version="254", mode="auto", filesystem="cgroup2fs",
                      memory=True, manager=True, no_service=False, answer=None,
                      verified=True, full_install=False, piped=False,
                      platform="Linux"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mocks = root / "bin"
            mocks.mkdir()
            log = root / "calls"
            commands = {
                "systemctl": """
printf '%s\\n' "$*" >> "$TEST_LOG"
case "$*" in
  *show-environment*) exit "$TEST_MANAGER_STATUS";;
  *--property=Version*) printf '%s\\n' "$TEST_VERSION";;
  *--property=DelegateSubgroup*)
    if [ "$TEST_VERIFIED" = 1 ]; then
      printf '%s\\n' 'Delegate=yes' 'DelegateSubgroup=supervisor'
    else
      printf '%s\\n' 'Delegate=no' 'DelegateSubgroup='
    fi;;
esac
""",
                "stat": 'printf "%s\\n" "$TEST_FILESYSTEM"',
                "grep": f"""
case "$*" in
  *"/sys/fs/cgroup/cgroup.controllers"*) exit "$TEST_MEMORY_STATUS";;
  *) exec '{shutil.which("grep")}' "$@";;
esac
""",
                "curl": 'printf "%s\\n" "curl $*" >> "$TEST_LOG"',
                "loginctl": 'printf "%s\\n" "Linger=yes"',
                "uname": 'case "$1" in -s) echo "$TEST_PLATFORM";; -m) echo x86_64;; esac',
            }
            for name, body in commands.items():
                path = mocks / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            env = dict(
                os.environ, PATH=f"{mocks}:/usr/bin:/bin",
                HOME=str(root / "home"), LONGX_HOME=str(root / "installed"),
                LONGX_CGROUP=mode, TEST_LOG=str(log), TEST_VERSION=version,
                TEST_FILESYSTEM=filesystem, TEST_MANAGER_STATUS="0" if manager else "1",
                TEST_MEMORY_STATUS="0" if memory else "1",
                TEST_VERIFIED="1" if verified else "0",
                TEST_PLATFORM=platform,
            )
            env.pop("LONGX_NO_SERVICE", None)
            if no_service:
                env["LONGX_NO_SERVICE"] = "1"
            if full_install:
                payload = root / "payload"
                (payload / "bin").mkdir(parents=True)
                binary = payload / "bin" / "longx"
                binary.write_text("#!/bin/sh\nprintf '%s\\n' 'longx 0.0.0'\n")
                binary.chmod(0o755)
                archive = root / "longx-0.0.0-linux-x86_64.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    bundle.add(payload, arcname="longx")
                env["LONGX_TARBALL"] = str(archive)
                # An existing install and old unit must also be refreshed.
                installed = root / "installed" / "app" / "bin"
                installed.mkdir(parents=True)
                shutil.copy2(binary, installed / "longx")
                (root / "installed" / "data").mkdir()
                unit = root / "home" / ".config" / "systemd" / "user" / "longx.service"
                unit.parent.mkdir(parents=True)
                unit.write_text("[Service]\nDelegate=memory\nDelegateSubgroup=supervisor\n")
                command = ["sh", str(SCRIPT)]
            else:
                command = ["sh", "-c", FUNCTIONS + """
configure_cgroup
printf 'SELECTED=%s\\n' "$CGROUP_ENABLED"
cgroup_service_properties
verify_cgroup_service
"""]
            script_input = ""
            if piped:
                script_input = command[2] + "\nprintf 'PIPE_SCRIPT_FINISHED\\n'\n"
                command = ["sh"]
            if answer is None:
                result = subprocess.run(command, env=env, capture_output=True,
                                        text=True, start_new_session=True, timeout=10)
                terminal = ""
            else:
                master, slave = pty.openpty()

                def own_terminal():
                    os.setsid()
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

                process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True,
                                           stdin=subprocess.PIPE if piped else None,
                                           preexec_fn=own_terminal)
                try:
                    if piped:
                        process.stdin.write(script_input)
                        process.stdin.flush()
                    terminal = ""
                    deadline = time.monotonic() + 5
                    while "[Y/n]" not in terminal and time.monotonic() < deadline:
                        if select.select([master], [], [], 0.1)[0]:
                            terminal += os.read(master, 4096).decode()
                    self.assertIn("[Y/n]", terminal)
                    os.write(master, answer.encode())
                    out, err = process.communicate(timeout=5)
                    result = subprocess.CompletedProcess(command, process.returncode, out, err)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    process.stdout.close()
                    process.stderr.close()
                    if process.stdin is not None:
                        process.stdin.close()
                    os.close(slave)
                    os.close(master)
            calls = log.read_text() if log.exists() else ""
            contents = unit.read_text() if full_install else ""
            return result, terminal, calls, contents

    def test_supported_systemd_keeps_supervisor_outside_tasks(self):
        for version in ("254", "257.8-1~deb13u2"):
            with self.subTest(version=version):
                result, _, _, _ = self.run_selection(version=version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("SELECTED=1", result.stdout)
                self.assertIn("Delegate=memory\nDelegateSubgroup=supervisor\n", result.stdout)
                self.assertIn("没有交互终端", result.stdout)

    def test_older_systemd_does_not_emit_unknown_properties(self):
        result, _, _, _ = self.run_selection(version="253")
        self.assertIn("SELECTED=0", result.stdout)
        self.assertIn("systemd < 254", result.stdout)
        self.assertNotIn("DelegateSubgroup=", result.stdout)

    def test_unknown_version_degrades_explicitly(self):
        result, _, _, _ = self.run_selection(version="unknown")
        self.assertIn("SELECTED=0", result.stdout)
        self.assertIn("无法确认", result.stdout)

    def test_v1_or_missing_memory_skips_protection(self):
        for options in ({"filesystem": "tmpfs"}, {"memory": False}):
            with self.subTest(options=options):
                result, _, _, _ = self.run_selection(**options)
                self.assertIn("SELECTED=0", result.stdout)
                self.assertIn("警告", result.stdout)

    def test_no_user_manager_or_no_service_does_not_probe_or_prompt(self):
        for options in ({"manager": False}, {"no_service": True}):
            with self.subTest(options=options):
                result, _, calls, _ = self.run_selection(**options)
                self.assertIn("SELECTED=0", result.stdout)
                self.assertNotIn("--property=Version", calls)
                self.assertNotIn("[Y/n]", result.stdout)

    def test_on_and_off_skip_question(self):
        for mode, selected in (("on", "1"), ("off", "0")):
            with self.subTest(mode=mode):
                result, _, _, _ = self.run_selection(mode=mode)
                self.assertIn("SELECTED=" + selected, result.stdout)
                self.assertNotIn("没有交互终端", result.stdout)

    def test_on_does_not_override_missing_prerequisites(self):
        result, _, _, _ = self.run_selection(mode="on", version="253")
        self.assertIn("SELECTED=0", result.stdout)

    def test_invalid_mode_fails_before_install(self):
        result, _, calls, _ = self.run_selection(mode="wrong")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LONGX_CGROUP", result.stderr)
        self.assertEqual(calls, "")

    def test_terminal_enter_defaults_to_enabled(self):
        result, terminal, _, _ = self.run_selection(answer="\n")
        self.assertIn("[Y/n]", terminal)
        self.assertIn("SELECTED=1", result.stdout)

    def test_terminal_can_decline(self):
        result, _, _, _ = self.run_selection(answer="n\n")
        self.assertIn("SELECTED=0", result.stdout)
        self.assertNotIn("DelegateSubgroup=", result.stdout)

    def test_invalid_answer_retries(self):
        result, _, _, _ = self.run_selection(answer="invalid\nn\n")
        self.assertIn("SELECTED=0", result.stdout)

    def test_piped_script_reads_answer_from_terminal_not_script(self):
        result, _, _, _ = self.run_selection(answer="n\n", piped=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELECTED=0", result.stdout)
        self.assertIn("PIPE_SCRIPT_FINISHED", result.stdout)

    def test_service_override_is_not_reported_as_success(self):
        result, _, _, _ = self.run_selection(mode="on", verified=False)
        self.assertIn("警告：无法确认 cgroup 委派生效", result.stdout)
        self.assertNotIn("已确认服务", result.stdout)

    def test_reinstall_refreshes_unit_reloads_and_restarts(self):
        result, _, calls, unit = self.run_selection(mode="on", full_install=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Delegate=memory\nDelegateSubgroup=supervisor", unit)
        self.assertNotIn("Delegate=no", unit)
        self.assertLess(calls.index("--property=Version"), calls.index("--user stop longx"))
        self.assertLess(calls.index("--user daemon-reload"), calls.index("--user restart longx"))
        self.assertLess(calls.index("--user restart longx"), calls.index("--property=DelegateSubgroup"))
        self.assertIn("已确认服务", result.stdout)

    def test_reinstall_can_remove_delegation(self):
        result, _, calls, unit = self.run_selection(mode="off", full_install=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Delegate", unit)
        self.assertIn("--user restart longx", calls)

    def test_non_linux_fails_before_service_or_download(self):
        result, _, calls, unit = self.run_selection(platform="Darwin", full_install=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("只支持 Linux", result.stderr)
        self.assertEqual(calls, "")
        self.assertIn("Delegate=memory", unit)


if __name__ == "__main__":
    unittest.main()
