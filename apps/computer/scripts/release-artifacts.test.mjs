import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mergeUpdates } from "./release-artifacts.mjs";
const targets = ["darwin-aarch64", "darwin-x86_64", "linux-x86_64", "linux-aarch64", "windows-x86_64"];
const records = () => targets.map(target => ({ target, version: "0.2.107", signature: "test-signature", url: `https://example.test/${target}` }));
test("manifest includes all signed desktop targets", () => {
  const manifest = mergeUpdates(records());
  assert.equal(manifest.version, "0.2.107");
  assert.equal(Object.keys(manifest.platforms).length, 5);
});
test("partial, duplicate and mixed-version updates fail closed", () => {
  assert.throws(() => mergeUpdates(records().slice(1)));
  const duplicate = records(); duplicate[0] = duplicate[1];
  assert.throws(() => mergeUpdates(duplicate));
  const mixed = records(); mixed[0].version = "0.2.108";
  assert.throws(() => mergeUpdates(mixed));
});
test("unsigned and insecure update records are refused", () => {
  const unsigned = records(); unsigned[0].signature = "";
  assert.throws(() => mergeUpdates(unsigned));
  const insecure = records(); insecure[0].url = "http://example.test/package";
  assert.throws(() => mergeUpdates(insecure));
});
test("macOS packaging keeps app alongside dmg and repair dispatch preserves tag", () => {
  const workflow = readFileSync(new URL("../../../.github/workflows/computer.yml", import.meta.url), "utf8");
  assert.match(workflow, /target: darwin-aarch64\s+bundles: app,dmg/);
  assert.match(workflow, /target: darwin-x86_64[\s\S]*?bundles: app\n/);
  assert(workflow.includes('hdiutil create -volname "Longx Computer" -srcfolder "$stage" -format UDZO -ov "$image"'));
  assert(workflow.includes('codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$image"'));
  assert(workflow.includes('codesign --verify --strict "$image"'));
  assert(workflow.includes('xcrun notarytool submit "$image"'));
  assert(workflow.includes('python3 ../../scripts/check-notarization.py "$RUNNER_TEMP/computer-dmg-notarization.json"'));
  assert(workflow.includes('xcrun stapler validate "$image"'));
  assert.equal((workflow.match(/ref: \$\{\{ inputs\.release_tag \|\| github\.ref \}\}/g) || []).length, 2);
  assert(workflow.includes("tag_name: ${{ inputs.release_tag || github.ref_name }}"));
});
