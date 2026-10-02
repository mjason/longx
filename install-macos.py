#!/usr/bin/env python3
"""Per-user Apple Silicon installer. Python 3.9+ is needed only for installation."""
import argparse
import datetime
import fcntl
import hashlib
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

LABEL = "com.longx.agent"
RELEASES = "https://github.com/mjason/longx/releases"


def validate_archive(archive):
    members = archive.getmembers()
    names = [str(PurePosixPath(m.name)) for m in members]
    if len(names) != len(set(names)):
        raise ValueError("Duplicate archive paths")
    links = {str(PurePosixPath(m.name)): m.linkname for m in members if m.issym()}
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "longx":
            raise ValueError("Unsafe archive path: " + member.name)
        if not (member.isfile() or member.isdir() or member.issym()):
            raise ValueError("Unsupported archive entry: " + member.name)
        if any(str(parent) in links for parent in path.parents):
            raise ValueError("Archive entry underneath a symbolic link: " + member.name)
        if member.issym():
            target = PurePosixPath(member.linkname)
            if target.is_absolute():
                raise ValueError("Absolute archive link")
            resolved = list(path.parent.parts)
            pending = list(target.parts)
            traversed = 0
            while pending:
                part = pending.pop(0)
                if part == ".":
                    continue
                if part == "..":
                    if len(resolved) <= 1:
                        raise ValueError("Archive link escapes release")
                    resolved.pop()
                    continue
                resolved.append(part)
                link = links.get("/".join(resolved))
                if link is not None:
                    traversed += 1
                    if traversed > 40 or PurePosixPath(link).is_absolute():
                        raise ValueError("Unsafe or cyclic archive link")
                    resolved.pop()
                    pending = list(PurePosixPath(link).parts) + pending
                if not resolved or resolved[0] != "longx":
                    raise ValueError("Archive link escapes release")
        # Never restore setuid/setgid or group/world write permissions.
        member.mode &= 0o755
    return members


def verify(tarball, checksum):
    digest = checksum.read_text().split()[0]
    if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise ValueError("Invalid SHA-256 file")
    sha = hashlib.sha256()
    with tarball.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    if sha.hexdigest() != digest.lower():
        raise ValueError("SHA-256 mismatch; installation untouched")


def launch_agent(app, data, port, home):
    return {
        "Label": LABEL,
        "ProgramArguments": [str(app / "bin/longx"), "start"],
        "WorkingDirectory": str(home),
        "EnvironmentVariables": {
            "HOME": str(Path.home()),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LONGX_DATA_DIR": str(data),
            "PORT": str(port),
            "PHX_HOST": "localhost",
            "LONGX_BIND_IP": "127.0.0.1",
            "LONGX_SERVICE": LABEL,
        },
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "StandardOutPath": str(home / "logs/stdout.log"),
        "StandardErrorPath": str(home / "logs/stderr.log"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="release version; default latest")
    parser.add_argument("--tarball", type=Path, help="local archive (requires adjacent .sha256)")
    parser.add_argument("--no-service", action="store_true", help="install only; stop an existing managed service")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Requires native Apple Silicon macOS (not a Rosetta terminal)")
    if os.getuid() == 0:
        parser.error("Run as your own user, not sudo/root")
    os.umask(0o077)
    home = Path(os.environ.get("LONGX_HOME", str(Path.home() / ".longx"))).expanduser()
    if not home.is_absolute() or home.is_symlink():
        parser.error("LONGX_HOME must be an absolute, non-symlink directory")
    home = home.resolve()
    if home == Path.home().resolve() or Path.home().resolve() not in home.parents:
        parser.error("LONGX_HOME must be a directory underneath your home")
    home.mkdir(mode=0o700, parents=True, exist_ok=True)
    if home.stat().st_uid != os.getuid() or home.stat().st_mode & 0o022:
        parser.error("Installation directory must be owned by you and not writable by other users")
    app, data = home / "app", home / "data"
    for name in ("app", "data", "backups", "logs", ".install.lock"):
        if (home / name).is_symlink():
            parser.error("Refusing symlink: " + str(home / name))
    port = int(os.environ.get("LONGX_PORT", "7788"))
    if not 1024 <= port <= 65535:
        parser.error("LONGX_PORT must be between 1024 and 65535")
    with (home / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        install(args, home, app, data, port)


def install(args, home, app, data, port):
    for name in ("data", "backups", "logs"):
        (home / name).mkdir(mode=0o700, exist_ok=True)
    unit = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    domain = "gui/" + str(os.getuid())
    service = domain + "/" + LABEL
    if unit.is_symlink():
        raise ValueError("Refusing symlink LaunchAgent")
    if unit.exists():
        old = plistlib.loads(unit.read_bytes())
        if old.get("ProgramArguments") != [str(app / "bin/longx"), "start"]:
            raise ValueError("Existing LaunchAgent belongs to a different installation")
    old_unit = unit.read_bytes() if unit.exists() else None
    with tempfile.TemporaryDirectory(prefix=".install-", dir=home) as temporary:
        stage = Path(temporary)
        tarball = args.tarball
        if tarball is None:
            version = args.version
            if not version:
                import json
                with urllib.request.urlopen("https://api.github.com/repos/mjason/longx/releases/latest", timeout=60) as response:
                    version = json.load(response)["tag_name"]
            version = version.removeprefix("v")
            if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", version):
                raise ValueError("Invalid release version")
            name = "longx-" + version + "-darwin-arm64.tar.gz"
            tarball = stage / name
            for suffix in ("", ".sha256"):
                with urllib.request.urlopen(RELEASES + "/download/v" + version + "/" + name + suffix, timeout=60) as response:
                    with Path(str(tarball) + suffix).open("wb") as output:
                        shutil.copyfileobj(response, output)
        verify(tarball, Path(str(tarball) + ".sha256"))
        with tarfile.open(tarball, "r:gz") as archive:
            members = validate_archive(archive)
            # All paths/links were checked before extracting anything.
            archive.extractall(stage, members=members)
        candidate = stage / "longx"
        if not (candidate / "bin/longx").is_file():
            raise ValueError("Archive has no release executable")
        clean_env = {"HOME": str(Path.home()), "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        subprocess.run([str(candidate / "bin/longx"), "version"], env=clean_env, check=True, timeout=60)
        active = subprocess.run(["launchctl", "print", service], capture_output=True).returncode == 0
        if active and old_unit is None:
            raise ValueError("Refusing to stop an unrecognized LaunchAgent")
        if active:
            subprocess.run(["launchctl", "bootout", service], check=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        previous = home / "backups" / ("app-" + stamp)
        swapped = False
        try:
            with tarfile.open(home / "backups" / ("data-" + stamp + ".tar.gz"), "w:gz") as backup:
                backup.add(data, arcname="data")
            if app.exists():
                app.rename(previous)
            candidate.rename(app)
            swapped = True
            if not args.no_service:
                unit.parent.mkdir(parents=True, exist_ok=True)
                pending = stage / "agent.plist"
                pending.write_bytes(plistlib.dumps(launch_agent(app, data, port, home)))
                os.replace(pending, unit)
                subprocess.run(["launchctl", "bootstrap", domain, str(unit)], check=True)
        except BaseException:
            if swapped:
                app.rename(home / "backups" / ("failed-app-" + stamp))
            if previous.exists():
                previous.rename(app)
            if old_unit is not None:
                unit.write_bytes(old_unit)
            elif unit.exists():
                unit.unlink()
            if active:
                subprocess.run(["launchctl", "bootstrap", domain, str(unit)], check=False)
            raise
    print("Installed. Open http://localhost:" + str(port) if not args.no_service else "Installed; service not started.")
    print("Backups: " + str(home / "backups") + " (program rollback does not undo database migrations).")


if __name__ == "__main__":
    main()
