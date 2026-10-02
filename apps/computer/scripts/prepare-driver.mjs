// Build-time packaging only. Pin/hash the complete platform archive, preserve
// runtime helpers and notices, but do not bundle a second CuaDriver.app.
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, readFile, writeFile, cp, readdir, stat, chmod } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { createWriteStream } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const version = "0.32.0";
const pins = {
  "darwin-arm64": "31f278f38015616a02142ccbb396721897cee4892927db103a31b297f60035a9",
  "darwin-x86_64": "0322e9316d81fbe34cbe8efe2eae83a32cf4dd86b9f34639cc0a4b3a6ed74868",
  "linux-arm64": "262439491f2fa9b718ba37bee3838fff4ad53c77a32f4a73aaf243bad3cd794c",
  "linux-x86_64": "998e63452c38b76a682da2d07f4bb24f0c1663d76c861a5dc0c345a7ead1f889",
  "windows-arm64": "51f5723a6734afb7125c92fe05835bb815f7c37b75e2332dd48ae184ddb0a9f8",
  "windows-x86_64": "6d70b45c8c901db773010dd720c8bb9d58c59bb301e9891c58ca1d3860e75652",
};
const os = process.platform === "win32" ? "windows" : process.platform;
const arch = process.arch === "x64" ? "x86_64" : process.arch;
const target = process.argv[2] || `${os}-${arch}`;
if (!pins[target]) throw new Error(`Unsupported target: ${target}`);
const packageName = `cua-driver-rs-${version}-${target}`;
const asset = packageName + (target.startsWith("windows") ? ".zip" : ".tar.gz");
const cache = path.join(root, ".driver-cache", target);
const archive = path.join(cache, asset);
await mkdir(cache, { recursive: true });
try { await stat(archive); } catch {
  const response = await fetch(`https://github.com/trycua/cua/releases/download/cua-driver-rs-v${version}/${asset}`);
  if (!response.ok || !response.body) throw new Error(`Driver download failed: ${response.status}`);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(archive));
}
const hash = createHash("sha256");
for await (const chunk of createReadStream(archive)) hash.update(chunk);
if (hash.digest("hex") !== pins[target]) throw new Error("Driver archive checksum mismatch; no package copied");
const extraction = path.join(cache, "extracted");
await mkdir(extraction, { recursive: true });
if (target.startsWith("windows")) {
  execFileSync("powershell", ["-NoProfile", "-NonInteractive", "-Command",
    "Expand-Archive -LiteralPath $env:LONGX_DRIVER_ARCHIVE -DestinationPath $env:LONGX_DRIVER_EXTRACT -Force"],
    { env: { ...process.env, LONGX_DRIVER_ARCHIVE: archive, LONGX_DRIVER_EXTRACT: extraction } });
} else {
  execFileSync("tar", ["-xzf", archive, "-C", extraction]);
}
const source = path.join(extraction, packageName);
const dest = path.join(root, "src-tauri", "resources", "driver");
await mkdir(dest, { recursive: true });
for (const name of await readdir(source)) {
  if (name === "CuaDriver.app") continue;
  await cp(path.join(source, name), path.join(dest, name), { recursive: true });
}
const binary = path.join(dest, target.startsWith("windows") ? "cua-driver.exe" : "cua-driver");
if (!target.startsWith("windows")) await chmod(binary, 0o755);
await writeFile(path.join(dest, "longx-driver.json"), JSON.stringify({ version, target, sha256: pins[target] }, null, 2));
console.log(`Packaged CUA Driver ${version} (${target}), verified SHA256. No system installation or permission changes.`);
