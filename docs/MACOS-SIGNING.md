# macOS release signing

The macOS release uses Developer ID Application signing and Apple notarization. Linux and Docker builds do not use Apple credentials.

Required repository Actions Secrets:

- `DEVELOPER_ID_P12_BASE64`: base64 P12 certificate including its private key.
- `DEVELOPER_ID_P12_PASSWORD`: P12 export password.
- `DEVELOPER_ID_IDENTITY`: full Developer ID Application identity name.
- `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`: Apple ID, team, and app-specific password.

A Developer ID identity may be reused across products of the same developer. Secrets stay out of Git. CI imports them into a temporary keychain and removes it even after failures.

After relocating dependencies, `scripts/sign-macos.py` signs every Mach-O file, including extensionless executables, NIFs, and bundled dylibs. Hardened runtime and secure timestamps are enabled. Only `beam.smp` receives `allow-jit`; library validation remains enabled because bundled code shares the same team.

CI submits a ZIP of the complete release to Apple and requires an explicit `Accepted` result before packaging/publishing. The tarball retains its existing name and installer compatibility. Standalone executable files and tarballs cannot receive stapled tickets; Gatekeeper retrieves the notarization ticket online. This does not promise offline Gatekeeper verification. A future DMG or PKG can carry a stapled ticket; signing PKG requires Developer ID Installer.

Run `python3 -B -m unittest discover -s test -p '*_test.py'` for installer/signing regression checks. The macOS Actions job additionally installs and starts the signed release, exercising Erlang JIT, crypto NIF loading, and application startup.
