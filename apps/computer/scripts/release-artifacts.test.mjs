import test from "node:test";
import assert from "node:assert/strict";
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
