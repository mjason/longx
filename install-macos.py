#!/usr/bin/env python3
"""Per-user Apple Silicon installer. Python 3.9+ is needed only for installation."""
import argparse
import datetime
import fcntl
import hashlib
import ipaddress
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
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


def bind_address(value):
    try:
        if "%" in value:
            raise ValueError("scoped addresses are not supported")
        return str(ipaddress.ip_address(value))
    except (ValueError, TypeError):
        raise ValueError("Bind address must be an IPv4 or IPv6 address without a port or scope") from None


def local_url(port, bind_ip):
    address = ipaddress.ip_address(bind_address(bind_ip))
    if address.is_unspecified:
        address = ipaddress.ip_address("127.0.0.1" if address.version == 4 else "::1")
    host = "[" + str(address) + "]" if address.version == 6 else str(address)
    return "http://" + host + ":" + str(port) + "/"


def launch_agent(app, data, port, home, bind_ip="127.0.0.1"):
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
            "LONGX_BIND_IP": bind_address(bind_ip),
            "LONGX_SERVICE": LABEL,
        },
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "StandardOutPath": str(home / "logs/stdout.log"),
        "StandardErrorPath": str(home / "logs/stderr.log"),
    }


def wait_until_unloaded(service, timeout=30):
    # bootout returns before launchd has finished terminating/removing the job.
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if subprocess.run(["launchctl", "print", service], capture_output=True).returncode != 0:
            return
        time.sleep(0.2)
    raise RuntimeError("LaunchAgent did not finish stopping: " + service)


def wait_until_ready(port, logs, timeout=60, *, bind_ip="127.0.0.1"):
    # Local readiness must not depend on a user's HTTP proxy configuration.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    url = local_url(port, bind_ip)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with opener.open(url, timeout=2) as response:
                if response.status == 200:
                    return
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError("Longx did not respond within " + str(timeout) +
                       " seconds; inspect " + str(logs / "stderr.log") +
                       " and " + str(logs / "stdout.log"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="release version; default latest")
    parser.add_argument("--tarball", type=Path, help="local archive (requires adjacent .sha256)")
    parser.add_argument("--no-service", action="store_true", help="install only; stop an existing managed service")
    parser.add_argument("--bind", type=bind_address, metavar="IP",
                        help="IPv4/IPv6 listen address; preserve existing setting on upgrade, otherwise 127.0.0.1")
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
    old = {}
    if unit.exists():
        old = plistlib.loads(unit.read_bytes())
        if old.get("ProgramArguments") != [str(app / "bin/longx"), "start"]:
            raise ValueError("Existing LaunchAgent belongs to a different installation")
    old_unit = unit.read_bytes() if unit.exists() else None
    bind_ip = bind_address(
        args.bind if args.bind is not None
        else old.get("EnvironmentVariables", {}).get("LONGX_BIND_IP", "127.0.0.1")
    )
    if not args.no_service and not ipaddress.ip_address(bind_ip).is_loopback:
        print("WARNING: listening on " + bind_ip +
              " exposes Longx to the network. There is no login access control; use a trusted network only.")
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
            wait_until_unloaded(service)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        previous = home / "backups" / ("app-" + stamp)
        swapped = False
        registered = False
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
                pending.write_bytes(plistlib.dumps(launch_agent(app, data, port, home, bind_ip)))
                os.replace(pending, unit)
                subprocess.run(["launchctl", "bootstrap", domain, str(unit)], check=True)
                registered = True
                # RunAtLoad can remain pending in a GUI domain's on-demand-only mode
                # (observed on macOS 26). Explicitly demand startup, then check HTTP.
                subprocess.run(["launchctl", "kickstart", service], check=True)
                wait_until_ready(port, home / "logs", bind_ip=bind_ip)
        except BaseException:
            if registered:
                subprocess.run(["launchctl", "bootout", service], check=False)
                wait_until_unloaded(service)
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
                subprocess.run(["launchctl", "kickstart", service], check=False)
            raise
    if args.no_service:
        print("Installed; service not started.")
    else:
        host = "[" + bind_ip + "]" if ":" in bind_ip else bind_ip
        print("Installed. Listening on " + host + ":" + str(port))
        print("Open " + local_url(port, bind_ip))
        if ipaddress.ip_address(bind_ip).is_unspecified:
            print("For other devices, use this Mac's LAN IP and port " + str(port) + ".")
    print("Backups: " + str(home / "backups") + " (program rollback does not undo database migrations).")


if __name__ == "__main__":
    main()
