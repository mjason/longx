// Runs the e2e scenarios against a running Longx, in order, and says what
// failed. Each scenario exports `run(harness)`; a thrown error fails it, a
// console error or an overflow the harness saw fails it too.
//   npm run e2e                    # every scenario
//   npm run e2e -- turn exchange   # by name
//   LONGX_E2E_URL=http://192.168.2.70:7788 LONGX_E2E_MODEL=plus npm run e2e
// Screenshots land in scripts/e2e/out/.
import fs from "node:fs";
import path from "node:path";
import { Harness, BASE } from "./lib.mjs";

const dir = path.join(path.dirname(new URL(import.meta.url).pathname), "scenarios");
const wanted = process.argv.slice(2);
const files = fs
  .readdirSync(dir)
  .filter((f) => f.endsWith(".mjs"))
  .sort()
  .filter((f) => wanted.length === 0 || wanted.some((w) => f.includes(w)));

console.log(`e2e against ${BASE}: ${files.length} scenario(s)`);
let failed = 0;
for (const file of files) {
  const name = file.replace(/^\d+-/, "").replace(/\.mjs$/, "");
  const started = Date.now();
  const h = new Harness(name);
  try {
    await h.start();
    const { run } = await import(path.join(dir, file));
    await run(h);
    await h.cleanup();
    if (h.problems.length) throw new Error(h.problems.join("\n  "));
    console.log(`  ok   ${name} (${((Date.now() - started) / 1000).toFixed(1)}s)`);
  } catch (e) {
    failed++;
    console.log(`  FAIL ${name} (${((Date.now() - started) / 1000).toFixed(1)}s)\n  ${e.message}`);
    await h.cleanup().catch(() => {});
  } finally {
    await h.stop();
  }
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
