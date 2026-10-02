# Local computer driver

Settings → Agent kernel includes a CUA Driver card beside obscura. This first
stage manages the local dependency only: it does not expose computer tools,
start a desktop service, grant permissions, or configure a remote connection.

`Longx.Computer.Runtime` pins CUA Driver 0.32.0 and the SHA-256 of each complete
release archive (from the upstream release metadata). All six macOS, Linux and
Windows x86-64/ARM64 distributions are mapped. The complete macOS archive
includes the signed `CuaDriver.app`; the bare-binary archive is intentionally
not used. Linux archives also retain their Wayland helpers, and Windows
archives retain their runtime helpers.

The installer reuses `Longx.Bundle`, with one asynchronous download at a time,
progress, checksum verification, layout verification and retry. It does not run
upstream installation scripts or alter PATH, autostart, permissions or system
application directories.

Downloaded packages live in:

```text
<data>/cua-driver/<version>/<target>/cua-driver-rs-<version>-<target>/
```

Dev data is under the project `data/`; production uses `LONGX_DATA_DIR`.
`LONGX_CUA_DRIVER` explicitly selects an existing binary. Arbitrary binaries on
PATH are not selected. Previous complete downloads remain usable when Longx
changes its pin; settings offers an upgrade for an older downloaded version.
Old packages are retained, not automatically removed.

Installation is not readiness:

- macOS needs the signed app to own Accessibility and Screen Recording grants.
- Windows needs the logged-in user's interactive desktop, not Session 0.
- Linux needs a graphical user session and its accessibility bus. X11 and the
  individual Wayland compositors have different capabilities.

The intended next stage is a Computer plug and a local authenticated HTTP MCP
connection, with desktop ownership, cancellation and screenshot handling.
CUA's current HTTP endpoint uses the legacy MCP profile; validate the pinned
release's session semantics before implementing it. Remote is explicitly out
of scope; future cross-machine routing belongs to Longx networking, not a
publicly exposed CUA endpoint.
