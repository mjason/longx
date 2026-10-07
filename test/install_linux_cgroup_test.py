"""The installer enables delegation only on systemd versions supporting it."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class LinuxCgroupInstallerTest(unittest.TestCase):
    def properties(self, version):
        source = Path("install.sh").read_text()
        start = source.index("cgroup_service_properties() {")
        end = source.index("\n}\n", start) + 3
        function = source[start:end]
        with tempfile.TemporaryDirectory() as directory:
            systemctl = Path(directory) / "systemctl"
            systemctl.write_text(f"#!/bin/sh\nprintf '%s\\n' 'systemd {version}'\n")
            systemctl.chmod(0o755)
            env = dict(os.environ, PATH=f"{directory}:/usr/bin:/bin")
            return subprocess.run(
                ["sh", "-c", function + "\ncgroup_service_properties\n"],
                env=env, capture_output=True, text=True, check=True,
            )

    def test_supported_systemd_keeps_supervisor_outside_tasks(self):
        result = self.properties("254")
        self.assertEqual(
            result.stdout, "Delegate=memory\nDelegateSubgroup=supervisor\n"
        )

    def test_older_systemd_does_not_emit_unknown_properties(self):
        result = self.properties("253")
        self.assertEqual(result.stdout, "")
        self.assertIn("cgroup", result.stderr)

    def test_unknown_version_degrades_explicitly(self):
        result = self.properties("unknown")
        self.assertEqual(result.stdout, "")
        self.assertIn("cgroup", result.stderr)
