"""Portable security checks; run with python3 -m unittest discover -s test -p '*_test.py'."""
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest
import hashlib
import io
import plistlib
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "install-macos.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class Archive:
    def __init__(self, members):
        self.members = members

    def getmembers(self):
        return self.members


class InstallerTest(unittest.TestCase):
    def test_paths_and_special_files_rejected(self):
        for name in ("/longx/bin", "longx/../../escape", "other/bin"):
            with self.assertRaises(ValueError):
                installer.validate_archive(Archive([tarfile.TarInfo(name)]))
        member = tarfile.TarInfo("longx/device")
        member.type = tarfile.CHRTYPE
        with self.assertRaises(ValueError):
            installer.validate_archive(Archive([member]))

    def test_links_cannot_escape_or_be_used_as_parents(self):
        link = tarfile.TarInfo("longx/lib")
        link.type = tarfile.SYMTYPE
        for target in ("/tmp", "../../tmp"):
            link.linkname = target
            with self.assertRaises(ValueError):
                installer.validate_archive(Archive([link]))
        link.linkname = "other"
        with self.assertRaises(ValueError):
            installer.validate_archive(Archive([link, tarfile.TarInfo("longx/lib/file")]))
        installer.validate_archive(Archive([link]))

    def test_permissions_sanitized(self):
        member = tarfile.TarInfo("longx/bin/longx")
        member.mode = 0o6777
        installer.validate_archive(Archive([member]))
        self.assertEqual(member.mode, 0o755)

    def test_chained_links_and_normalized_link_parents(self):
        link = tarfile.TarInfo("longx/./lib")
        link.type = tarfile.SYMTYPE
        link.linkname = "."
        with self.assertRaises(ValueError):
            installer.validate_archive(Archive([link, tarfile.TarInfo("longx/lib/file")]))
        chain = tarfile.TarInfo("longx/dir/link")
        chain.type = tarfile.SYMTYPE
        chain.linkname = "../lib/../outside"
        with self.assertRaises(ValueError):
            installer.validate_archive(Archive([link, chain]))

    def test_checksum_required_and_verified(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "app.tar.gz"
            checksum = Path(temp) / "app.tar.gz.sha256"
            archive.write_bytes(b"release")
            with self.assertRaises(FileNotFoundError):
                installer.verify(archive, checksum)
            checksum.write_text(hashlib.sha256(b"release").hexdigest() + "  app.tar.gz\n")
            installer.verify(archive, checksum)
            archive.write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                installer.verify(archive, checksum)

    def test_agent_is_loopback_and_paths_are_not_shell_commands(self):
        home = Path("/Users/example/space & directory")
        agent = installer.launch_agent(home / "app", home / "data", 7788, home)
        self.assertEqual(agent["EnvironmentVariables"]["LONGX_BIND_IP"], "127.0.0.1")
        self.assertEqual(agent["ProgramArguments"], [str(home / "app/bin/longx"), "start"])

    def test_agent_accepts_explicit_ipv4_and_ipv6_bind_addresses(self):
        home = Path("/Users/example/.longx")
        for address in ("0.0.0.0", "192.168.2.203", "::", "::1"):
            with self.subTest(address=address):
                agent = installer.launch_agent(home / "app", home / "data", 7788, home, address)
                self.assertEqual(agent["EnvironmentVariables"]["LONGX_BIND_IP"], address)

    def test_invalid_bind_argument_is_rejected_before_installation(self):
        for address in ("localhost", "0.0.0.0:7788", "999.1.2.3", "fe80::1%en0", ""):
            with self.subTest(address=address), patch(
                "sys.argv", ["install-macos.py", "--bind", address]
            ), patch.object(installer, "install") as install, patch(
                "sys.stderr", new_callable=io.StringIO
            ), self.assertRaises(SystemExit) as error:
                installer.main()
            self.assertEqual(error.exception.code, 2)
            install.assert_not_called()

    def test_bind_argument_reaches_installation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch("sys.argv", ["install-macos.py", "0.2.115", "--bind", "0.0.0.0"]), patch.object(
                installer.platform, "system", return_value="Darwin"
            ), patch.object(installer.platform, "machine", return_value="arm64"), patch.object(
                installer.os, "getuid", return_value=501
            ), patch.object(installer.os, "umask"), patch.object(
                installer.Path, "stat", autospec=True,
                return_value=SimpleNamespace(st_uid=501, st_mode=0o40700)
            ), patch.object(installer.Path, "home", return_value=root), patch.dict(
                installer.os.environ, {}, clear=True
            ), patch.object(installer, "install") as install:
                installer.main()
            self.assertEqual(install.call_args.args[0].bind, "0.0.0.0")
            self.assertEqual(install.call_args.args[0].version, "0.2.115")

    def test_health_check_uses_loopback_for_wildcards_and_specific_address_otherwise(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value.status = 200
        cases = [
            ("0.0.0.0", "http://127.0.0.1:7788/"),
            ("192.168.2.203", "http://192.168.2.203:7788/"),
            ("::", "http://[::1]:7788/"),
            ("::1", "http://[::1]:7788/"),
        ]
        for address, url in cases:
            with self.subTest(address=address), patch.object(
                installer.urllib.request, "build_opener"
            ) as opener:
                opener.return_value.open.return_value = response
                installer.wait_until_ready(7788, Path("/example/logs"), bind_ip=address)
                self.assertEqual(opener.return_value.open.call_args.args[0], url)
                self.assertEqual(opener.call_args.args[0].proxies, {})

    def test_health_check_retries_until_http_200_without_proxy(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value.status = 200
        with patch.object(installer.urllib.request, "build_opener") as opener, patch.object(
            installer.time, "sleep"
        ) as sleep:
            opener.return_value.open.side_effect = [OSError("not listening yet"), response]
            installer.wait_until_ready(7788, Path("/example/logs"))
            self.assertEqual(opener.call_args.args[0].proxies, {})
            self.assertEqual(opener.return_value.open.call_count, 2)
            self.assertEqual(opener.return_value.open.call_args.args[0], "http://127.0.0.1:7788/")
            sleep.assert_called_once()

    def test_health_timeout_reports_logs(self):
        with patch.object(installer.urllib.request, "build_opener") as opener, patch.object(
            installer.time, "monotonic", side_effect=[0, 0, 61]
        ), patch.object(installer.time, "sleep"):
            opener.return_value.open.side_effect = OSError("connection refused")
            with self.assertRaisesRegex(RuntimeError, "/example/logs"):
                installer.wait_until_ready(7788, Path("/example/logs"))

    def test_waits_for_bootout_to_finish_before_continuing(self):
        with patch.object(installer.subprocess, "run", side_effect=[
            SimpleNamespace(returncode=0), SimpleNamespace(returncode=1)
        ]) as command, patch.object(installer.time, "sleep") as sleep:
            installer.wait_until_unloaded("gui/501/com.longx.agent")
            self.assertEqual(command.call_count, 2)
            sleep.assert_called_once()

    def fixture(self, root):
        home = root / ".longx"
        (home / "app").mkdir(parents=True)
        (home / "app/old").write_text("old application")
        (home / "data").mkdir()
        (home / "data/database").write_text("valuable data")
        archive = root / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            member = tarfile.TarInfo("longx/bin/longx")
            member.mode = 0o755
            member.size = 3
            tar.addfile(member, io.BytesIO(b"new"))
        Path(str(archive) + ".sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest())
        args = SimpleNamespace(tarball=archive, no_service=True, bind=None)
        return home, args

    def test_install_persists_bind_and_preserves_it_on_upgrade_unless_overridden(self):
        cases = [
            (None, None, "127.0.0.1"),
            (None, "0.0.0.0", "0.0.0.0"),
            ("0.0.0.0", None, "0.0.0.0"),
            ("192.168.2.203", None, "192.168.2.203"),
            ("0.0.0.0", "127.0.0.1", "127.0.0.1"),
            (None, "::", "::"),
        ]
        for previous, requested, expected in cases:
            with self.subTest(previous=previous, requested=requested), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                home, args = self.fixture(root)
                args.no_service = False
                args.bind = requested
                unit = root / "Library/LaunchAgents/com.longx.agent.plist"
                if previous is not None:
                    unit.parent.mkdir(parents=True)
                    old = installer.launch_agent(home / "app", home / "data", 7788, home)
                    old["EnvironmentVariables"]["LONGX_BIND_IP"] = previous
                    unit.write_bytes(plistlib.dumps(old))
                with patch.object(installer.Path, "home", return_value=root), patch.object(
                    installer.subprocess, "run", return_value=SimpleNamespace(returncode=1)
                ), patch.object(installer, "wait_until_ready") as ready:
                    installer.install(args, home, home / "app", home / "data", 7788)
                agent = plistlib.loads(unit.read_bytes())
                self.assertEqual(agent["EnvironmentVariables"]["LONGX_BIND_IP"], expected)
                self.assertEqual(ready.call_args.kwargs["bind_ip"], expected)

    def test_invalid_existing_bind_fails_before_touching_the_running_service(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, args = self.fixture(root)
            args.no_service = False
            unit = root / "Library/LaunchAgents/com.longx.agent.plist"
            unit.parent.mkdir(parents=True)
            old = installer.launch_agent(home / "app", home / "data", 7788, home)
            old["EnvironmentVariables"]["LONGX_BIND_IP"] = "invalid"
            original = plistlib.dumps(old)
            unit.write_bytes(original)
            with patch.object(installer.Path, "home", return_value=root), patch.object(
                installer.subprocess, "run"
            ) as command, self.assertRaises(ValueError):
                installer.install(args, home, home / "app", home / "data", 7788)
            command.assert_not_called()
            self.assertEqual(unit.read_bytes(), original)
            self.assertEqual((home / "app/old").read_text(), "old application")

    def test_install_preserves_data_and_previous_application(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, args = self.fixture(root)
            with patch.object(installer.Path, "home", return_value=root), patch.object(
                installer.subprocess, "run", return_value=SimpleNamespace(returncode=1)
            ):
                installer.install(args, home, home / "app", home / "data", 7788)
            self.assertEqual((home / "data/database").read_text(), "valuable data")
            self.assertEqual((home / "app/bin/longx").read_bytes(), b"new")
            self.assertEqual(len(list((home / "backups").glob("app-*/old"))), 1)
            self.assertEqual(len(list((home / "backups").glob("data-*.tar.gz"))), 1)

    def test_checksum_failure_does_not_stop_or_replace_existing_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, args = self.fixture(root)
            args.tarball.write_bytes(b"corrupt")
            with patch.object(installer.Path, "home", return_value=root), patch.object(
                installer.subprocess, "run"
            ) as command, self.assertRaises(ValueError):
                installer.install(args, home, home / "app", home / "data", 7788)
            command.assert_not_called()
            self.assertEqual((home / "app/old").read_text(), "old application")

    def test_installer_bootstraps_kickstarts_then_checks_health(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, args = self.fixture(root)
            args.no_service = False
            events = []

            def command(argv, **kwargs):
                events.append(argv[:2])
                return SimpleNamespace(returncode=1 if argv[:2] == ["launchctl", "print"] else 0)

            with patch.object(installer.Path, "home", return_value=root), patch.object(
                installer.subprocess, "run", side_effect=command
            ), patch.object(installer, "wait_until_ready", side_effect=lambda *a, **kw: events.append(["health"])):
                installer.install(args, home, home / "app", home / "data", 7788)
            self.assertEqual(events[-3:], [["launchctl", "bootstrap"], ["launchctl", "kickstart"], ["health"]])

    def test_health_failure_unloads_new_service_before_restoring_old_one(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, args = self.fixture(root)
            args.no_service = False
            args.bind = "127.0.0.1"
            unit = root / "Library/LaunchAgents/com.longx.agent.plist"
            unit.parent.mkdir(parents=True)
            original = plistlib.dumps(installer.launch_agent(home / "app", home / "data", 7789, home, "0.0.0.0"))
            unit.write_bytes(original)
            events = []

            def command(argv, **kwargs):
                events.append(argv[:2])
                if argv[:2] == ["launchctl", "bootout"] and len(events) > 4:
                    self.assertTrue((home / "app/bin/longx").exists(), "new app moved before unload")
                return SimpleNamespace(returncode=0)

            with patch.object(installer.Path, "home", return_value=root), patch.object(
                installer.subprocess, "run", side_effect=command
            ), patch.object(installer, "wait_until_unloaded"), patch.object(
                installer, "wait_until_ready", side_effect=RuntimeError("startup failed")
            ), self.assertRaisesRegex(
                RuntimeError, "startup failed"
            ):
                installer.install(args, home, home / "app", home / "data", 7788)
            self.assertEqual(events[-3:], [["launchctl", "bootout"], ["launchctl", "bootstrap"], ["launchctl", "kickstart"]])
            self.assertEqual((home / "app/old").read_text(), "old application")
            self.assertEqual(unit.read_bytes(), original)

    def test_bootstrap_failure_restores_program_and_plist(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, args = self.fixture(root)
            args.no_service = False
            unit = root / "Library/LaunchAgents/com.longx.agent.plist"
            unit.parent.mkdir(parents=True)
            original = plistlib.dumps(installer.launch_agent(home / "app", home / "data", 7789, home))
            unit.write_bytes(original)

            def command(argv, **kwargs):
                if argv[:2] == ["launchctl", "bootstrap"] and kwargs.get("check"):
                    raise installer.subprocess.CalledProcessError(1, argv)
                return SimpleNamespace(returncode=0)

            with patch.object(installer.Path, "home", return_value=root), patch.object(
                installer.subprocess, "run", side_effect=command
            ), patch.object(installer, "wait_until_unloaded"), self.assertRaises(installer.subprocess.CalledProcessError):
                installer.install(args, home, home / "app", home / "data", 7788)
            self.assertEqual((home / "app/old").read_text(), "old application")
            self.assertEqual(unit.read_bytes(), original)
            self.assertEqual((home / "data/database").read_text(), "valuable data")
