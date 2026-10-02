# Longx Computer

Independent Tauri 2 desktop app, embedding CUA Driver 0.32.0. No model or
Elixir runtime is bundled. The Rust host directly owns `serve --embedded` and
private per-client MCP proxies. Do not launch a separate CuaDriver.app.

## Build

Install Rust, the platform's Tauri prerequisites, and Node.js. Then:

```sh
cd apps/computer
npm install
npm run prepare:driver
npm run dev
# macOS app bundle:
npm run build
# Windows/Linux installers: use the appropriate Tauri --bundles option
```

The build-time packaging script verifies the fixed platform archive SHA256 and
copies the binary, helper files and notices. It never runs upstream installers.
Generated resources, archive cache and compilation output are gitignored.
Cross-building requires preparing the matching target explicitly.
The `predev` / `prebuild` steps generate the desktop theme directly from
`assets/css/app.css`, keeping colors and fonts aligned with the Longx workbench.

On macOS use a stable `com.longx.computer` identity, sign nested executables
before signing/notarizing the enclosing app, and distribute with Developer ID.
Ad-hoc developer builds are not production-signed and grants may need to be
renewed after rebuilds. The host must be a real app launched through
LaunchServices; `cargo run` from Terminal is not a permission-attribution test.
Do not enable App Sandbox without a separate compatibility assessment.

## Use

The UI requests Accessibility and Screen Recording as Longx Computer. Grant
them in System Settings, then restart the service; if cached state persists,
fully quit/reopen the app. Embedded Driver never requests a second app grant.
Windows requires an interactive desktop, not Session 0; higher-integrity targets
may reject input. Linux needs the graphical user/accessibility session, and
Wayland portal authorization may be per-session.

Default HTTP MCP URL: `http://127.0.0.1:7797/mcp`. Port conflicts are errors, not
silent port changes. Start/restart is explicit. The access key is randomly
generated and kept in the platform credential store; reveal it only in the local
UI and paste it into Longx's masked settings field. Revoking the key first stops
the service and ends all sessions.

Non-loopback listening requires an explicit checkbox. Authentication is always
required; browser Origin requests are rejected and no CORS is provided. HTTP
is **not encrypted**: only use it on trusted networks. Put an HTTPS reverse
proxy in front of it (or use an encrypted tunnel) for untrusted networks.
Bind the app to loopback when terminating TLS on the same machine.
Configure firewall rules yourself; the app does not open them automatically.

One desktop lease across all clients. The UI can stop input and the entire
Driver generation. Foreground/full-display operations need approval in both
the app and Longx. Screenshots contain real computer data and are sent to
Longx's configured model. Optional perception and CUA Spaces are not bundled.
CUA's default content-free telemetry is not silently changed.

## Updates and permission recovery

The app offers explicit check/install actions through Tauri's signed updater.
Release builds embed `LONGX_COMPUTER_UPDATE_URL` (HTTPS Tauri update manifest)
and `LONGX_COMPUTER_UPDATE_PUBLIC_KEY` (public key only). Both must be present
at build time; debug builds disable updating so a build-tree app cannot replace
itself with a production package. Generate updater artifacts using
`npm run build -- --config src-tauri/tauri.release.conf.json` and provide
`TAURI_SIGNING_PRIVATE_KEY` / `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` through the
release secret store, never source control or chat. Publish the matching
platform artifacts, `.sig` signatures and Tauri manifest over HTTPS.
No update feed or signing key is provisioned by this source change.

Updater signatures authenticate the archive; they are **not** macOS application
signatures. Every macOS release must use the same Developer ID team/designated
requirement and `com.longx.computer`, be notarized, and replace the installed
bundle in place (prefer a stable `/Applications/Longx Computer.app` location).
Do not change keyring service/account or the app data location. Permission
retention is expected under a stable identity, not guaranteed by the updater;
ad-hoc builds use a changing code hash and cannot provide it. Windows releases
also need a stable Authenticode publisher; Linux portal grants may still expire.

Installation refuses an active desktop lease, verifies downloads before
stopping the runtime, checks again for a task started during download, then
stops owned Driver/proxies before replacement. It never rotates the access key
or resets permissions as part of an update. After installation, quit and reopen
the app, start the service and reconnect Longx. Windows' installer may exit
the app automatically.

Permission recovery is separate and explicit. The local UI provides refresh
and a confirmed per-permission “重新授权” action. On macOS this stops the
service and runs `tccutil reset Accessibility|ScreenCapture com.longx.computer`,
never a global reset. It opens System Settings and asks the person to quit,
reopen and request authorization again. No reset occurs on startup/update,
and no automatic click grants permission. A denied/no-op native request now
opens settings and explains the next step rather than silently succeeding.

## HTTP profile

JSON-RPC POST `/mcp`, Bearer authentication, legacy MCP `2025-06-18`.
`initialize` returns `Mcp-Session-Id`; send it on every later request.
DELETE `/mcp` with that header cancels/releases the client. `tools/list` is
curated. `start_session` / `end_session` manage the exclusive desktop lease.
Sessions survive TCP reconnection, but not app/Driver restarts. Idle sessions
expire after 90 seconds; Longx pings every 15 seconds.
Timeout or cancellation discards the proxy and never retries input.

The original Driver HTTP transport is not exposed. The app's HTTP adapter
wraps private stdio MCP proxies so remote TCP connections don't own Driver
lifecycle. Restart means reconnect and observe again; do not replay unknown
actions. If a network client disappears without DELETE, its lease can remain
until expiry; the local stop button remains available.

## Tests

```sh
npm test
```

Core HTTP tests use an isolated fake MCP executable, never a real desktop.
Real GUI/permission checks require a packaged app and interactive user.
`npm run test:ui` uses the workspace's `assets` Playwright dependency and an
installed Chrome, with mocked IPC. It never actually resets permissions or
installs an update.

CUA embedding reference:
https://github.com/trycua/cua/blob/cua-driver-rs-v0.32.0/libs/cua-driver/rust/Skills/cua-driver/EMBEDDING.md
