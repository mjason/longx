# Installation and operations

[Back to Longx](../README.md) · [Detailed reference (中文)](reference.zh-CN.md)

## Linux release

The packaged release supports Linux x86_64 and arm64 with glibc ≥ 2.39
(Ubuntu 24.04, Debian 13, or newer). It includes the Erlang runtime, Go shim, and built UI;
Elixir, Node, and Go are not required to run it. Install `git` for the Git workspace features.
The headless browser and certificate tool are verified and downloaded on first use.

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

The installer verifies the release checksum, installs under `~/.longx`, and starts a
`systemd --user` service when available. Open `http://<host>:7788`, configure a model
under **Settings → Providers**, then add a project directory.

No root access is needed. Provider credentials are encrypted in the data directory;
configure them in the UI rather than pasting secrets into a conversation.

## macOS Apple Silicon release

macOS 14 or newer, native ARM64 (M1 and later; not a Rosetta terminal), Python 3.9+:

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install-macos.sh | sh
# Or a specific application version:
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install-macos.sh | sh -s -- 0.2.106
```

The shell entry point downloads the latest released Python installer completely over
HTTPS before running it. It does not install Python or bypass system protections.
Piping a script executes downloaded code; to inspect it first, download
[install-macos.py](../install-macos.py), review it, and run:

```sh
python3 install-macos.py
# Or a specific version:
python3 install-macos.py 0.2.106
```

Python is needed only by the installer, not by the installed application. The native
archive includes ERTS, the shim, UI, and non-system native libraries. No Elixir,
Node, Go, Docker, or sudo is required. `git` is optional for workspace Git features.

The installer defaults to `~/.longx`, verifies SHA-256 and archive paths before
stopping the existing service, and starts the user LaunchAgent `com.longx.agent`.
It listens **only on 127.0.0.1**, at `http://localhost:7788`. It starts at login
and uses your account's permissions. Logs are in `~/.longx/logs`.

Repeat the installer to upgrade (the web self-upgrader currently supports Linux
only). It retains previous applications and stopped-service data snapshots in
`~/.longx/backups`, uses an exclusive install lock, and restores the prior program
if swapping, registering, or starting the service fails. After registration the
installer explicitly starts the LaunchAgent and waits up to 60 seconds for HTTP 200
on the local port before reporting success. Check the logs for later runtime issues.
On upgrades it also waits for launchd to fully remove the old service before
backing up data or registering the replacement.
Restoring an old application does not reverse database migrations; use its matching
data backup if needed.

Options: `LONGX_HOME` (a directory underneath your home), `LONGX_PORT`, `--no-service`,
or `--tarball /path/to/longx-VERSION-darwin-arm64.tar.gz` (the adjacent `.sha256`
file is mandatory, including local installs). `--no-service` stops an existing
managed service but leaves the new installation stopped.

```sh
launchctl bootout "gui/$(id -u)/com.longx.agent"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.longx.agent.plist"
```

Starting with **v0.2.106**, the macOS release is **Developer ID Application signed
and Apple notarized**. Earlier v0.2.104–v0.2.105 packages were ad-hoc signed only.
CI requires Apple's explicit `Accepted` result before publishing the macOS archive.
Bare executables and tarballs cannot carry stapled tickets, so Gatekeeper may need
network access to retrieve Apple's notarization record.
Checksums detect corruption; a checksum downloaded from the same GitHub release
is not independent proof of publisher identity. The installer does not remove
quarantine or disable Gatekeeper. If macOS blocks execution, do not disable system
protections; inspect the source and follow your organization's software policy.

See the [step-by-step macOS guide (中文)](installation-macos.zh-CN.md) or
[release signing configuration](MACOS-SIGNING.md).

## Linux installer options

To choose installation options, download [install.sh](../install.sh), review it, then run:

```sh
LONGX_HOME=~/apps/longx LONGX_PORT=8080 sh install.sh
LONGX_NO_SERVICE=1 sh install.sh
```

Without systemd, the installer prints a manual start command. With the default paths:

```sh
LONGX_DATA_DIR=~/.longx/data PORT=7788 ~/.longx/app/bin/longx start
```

For a user service that should stay up after logout, your system may require enabling
lingering with `loginctl enable-linger "$USER"`.
Logs: `journalctl --user -u longx -f`.

You can also download a release archive from [GitHub Releases](https://github.com/mjason/longx/releases).

## Docker

Images support Linux x86_64 / arm64:
`ghcr.io/mjason/longx:latest` or `ghcr.io/mjason/longx:<version>`.

```sh
mkdir longx && cd longx
curl -fsSLO https://raw.githubusercontent.com/mjason/longx/main/docker-compose.yml
mkdir workspace
docker compose up -d
```

Put your projects under `workspace/`; in Longx, select their paths under `/workspace`.
Open `http://<host>:7788`.

The [Compose file](../docker-compose.yml) persists three things: application data, the
agent's home directory, and your project directories. The container runs as uid 1000;
bind-mounted project files must be writable by that user. Review its ports, mounts, and
`LONGX_PUBLIC_URL` before deployment.

To upgrade a container:

```sh
docker compose pull
docker compose up -d
```

## HTTPS and mobile

In **Settings → HTTPS**, supply your domain and a DNS-provider credential scoped to DNS
changes. Longx obtains and renews a Let's Encrypt certificate through DNS validation;
the server itself does not need to be publicly reachable. Add a DNS record pointing
the name to the server address your devices can reach.

HTTPS listens on port 7443 alongside HTTP on 7788. If DNS setup goes wrong,
`http://<host>:7788/settings/https` remains reachable without redirecting.
A TLS reverse proxy is also supported.

Set the external URL in settings (or `LONGX_PUBLIC_URL` for deployment) so third-party
login callbacks return to the correct address. HTTPS enables installed web-app features
and makes remote OAuth callbacks easier. For Android, the
[native shell](https://github.com/mjason/longx-android) also works on a trusted LAN over HTTP.

## Upgrades and backups

For a packaged release, use **Settings → Version & Updates**, or rerun the installer.
Active turns may be interrupted by a restart. The UI upgrade creates a database snapshot;
the installer backs up the data directory and keeps the previous application as `app.old`.
The UI selects Linux x86_64/ARM64 or macOS Apple Silicon release packages.
On macOS it restarts the installer-managed `com.longx.agent` LaunchAgent in
the current user's GUI domain; Linux uses its systemd user service. Set
`LONGX_SERVICE` for a custom service label. An unregistered service requires
a manual restart after installation. Intel macOS and Windows main-program
self-upgrade packages are not currently published.

Back up the entire `~/.longx/data` directory, including `cloak_key` and `secret_key_base`.
Losing `cloak_key` makes existing encrypted provider credentials unreadable.
Project working directories are separate and need their own backups or version control.

`sh install.sh --rollback` restores the previous application. If an upgrade included
database migrations, restore the matching data backup while the service is stopped too;
restoring only the old executable may not be enough. See the
[detailed upgrade and rollback reference](reference.zh-CN.md#升级).

## Trust, permissions, and moving machines

Longx has no command sandbox: agents run as the user running Longx. Use a dedicated
environment when you need isolation, and review projects and shared `.longx` code before
enabling the project's trust switch.

To reuse project behavior on another machine, clone the repository, configure provider
credentials and matching model aliases there, add the project, and review/enable its
shared `.longx` definitions. `.longx/local/` stays private to the original machine unless
you deliberately transfer it. Project definitions do not include server conversations or
credentials; migrating those requires a backup of application data.

For source builds, see [Development](development.md).
