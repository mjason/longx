import { readFile, writeFile, readdir, mkdir, cp } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const config = JSON.parse(await readFile(path.join(root, "src-tauri/tauri.conf.json"), "utf8"));
const version = config.version;
const dist = path.join(root, "dist");
const mode = process.argv[2];
const targets = ["darwin-aarch64", "darwin-x86_64", "linux-x86_64", "linux-aarch64", "windows-x86_64"];
export function mergeUpdates(records) {
  if (records.length !== targets.length || new Set(records.map(record => record.target)).size !== targets.length) {
    throw new Error("Signed update manifest requires every desktop target exactly once");
  }
  const versions = new Set(records.map(record => record.version));
  if (versions.size !== 1) throw new Error("Update target versions differ");
  const platforms = {};
  for (const record of records) {
    if (!targets.includes(record.target) || !record.signature || !record.url.startsWith("https://")) throw new Error("Invalid update record");
    platforms[record.target] = { signature: record.signature, url: record.url };
  }
  return { version: records[0].version, notes: `Longx Computer ${records[0].version}`, pub_date: new Date().toISOString(), platforms };
}
async function files(dir) {
  const found = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory() && !entry.name.endsWith(".app")) found.push(...await files(full));
    else if (entry.isFile()) found.push(full);
  }
  return found;
}
if (mode === "version") {
  const pkg = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
  const cargo = await readFile(path.join(root, "src-tauri/Cargo.toml"), "utf8");
  const mix = await readFile(path.join(root, "../../mix.exs"), "utf8");
  if (pkg.version !== version || !cargo.includes(`version = "${version}"`) || !mix.includes(`version: "${version}"`)) throw new Error("App and Longx release versions must agree");
  if (process.env.GITHUB_REF?.startsWith("refs/tags/v") && process.env.GITHUB_REF_NAME !== `v${version}`) throw new Error("Tag does not match source version");
  console.log(`Verified release version ${version}`);
} else if (mode === "package") {
  const target = process.env.COMPUTER_TARGET;
  if (!targets.includes(target)) throw new Error("Unknown desktop target");
  const prefix = `longx-computer-${version}-${target}`;
  await mkdir(dist, { recursive: true });
  const bundle = path.join(root, "src-tauri/target/release/bundle");
  const archives = (await files(bundle)).filter(file => /\.(dmg|exe|AppImage|deb)$/.test(file) || file.endsWith(".app.tar.gz"));
  if (!archives.length) throw new Error("No installer bundles produced");
  let update;
  for (const archive of archives) {
    const suffix = archive.endsWith(".app.tar.gz") ? ".app.tar.gz" : path.extname(archive);
    const name = prefix + suffix;
    await cp(archive, path.join(dist, name));
    const hash = createHash("sha256").update(await readFile(archive)).digest("hex");
    await writeFile(path.join(dist, name + ".sha256"), `${hash}  ${name}\n`);
    if (process.env.COMPUTER_UPDATER_ENABLED === "true") {
      const updateSuffix = target.startsWith("darwin") ? ".app.tar.gz" : target.startsWith("linux") ? ".AppImage" : ".exe";
      if (suffix === updateSuffix) {
        const signature = (await readFile(archive + ".sig", "utf8")).trim();
        await cp(archive + ".sig", path.join(dist, name + ".sig"));
        update = { target, version, signature, url: `https://github.com/${process.env.GITHUB_REPOSITORY}/releases/download/v${version}/${name}` };
      }
    }
  }
  if (target.startsWith("darwin")) {
    execFileSync("ditto", ["-c", "-k", "--keepParent", path.join(bundle, "macos/Longx Computer.app"), path.join(dist, prefix + ".app.zip")]);
  }
  if (process.env.COMPUTER_UPDATER_ENABLED === "true") {
    if (!update) throw new Error("Signed updater artifact missing");
    await writeFile(path.join(dist, `update-${target}.json`), JSON.stringify(update));
  }
  console.log(`Packaged ${target} installers${update ? " and signed update" : " (updater disabled)"}`);
} else if (mode === "manifest") {
  const records = (await readdir(dist)).filter(name => /^update-.*\.json$/.test(name));
  if (records.length) {
    const manifest = mergeUpdates(await Promise.all(records.map(async name => JSON.parse(await readFile(path.join(dist, name), "utf8")))));
    await writeFile(path.join(dist, "computer-latest.json"), JSON.stringify(manifest, null, 2) + "\n");
    console.log("Complete signed updater manifest generated");
  } else console.log("Updater is disabled; publishing installers without a feed");
} else if (mode !== undefined) throw new Error("Use version, package or manifest");
