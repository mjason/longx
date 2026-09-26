import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { afterEach, describe, expect, test } from "vitest";
import { compressDir, entryOverBudget } from "./plugins";

let dir: string;
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe("precompress: the built files sent compressed (Plug.Static serves the .br / .gz beside a file)", () => {
  test("every text asset gets a .gz and a .br that decompress to it; a tiny file and an image are left alone", () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "longx-precompress-"));
    const js = "export const x = 1;\n".repeat(2_000);
    fs.writeFileSync(path.join(dir, "index-abc.js"), js);
    fs.mkdirSync(path.join(dir, "nested"));
    fs.writeFileSync(path.join(dir, "nested", "app.css"), "body{color:red}\n".repeat(500));
    fs.writeFileSync(path.join(dir, "tiny.js"), "1");
    fs.writeFileSync(path.join(dir, "logo.png"), Buffer.alloc(4096, 7));

    expect(compressDir(dir)).toBe(2);
    expect(zlib.gunzipSync(fs.readFileSync(path.join(dir, "index-abc.js.gz"))).toString()).toBe(js);
    expect(zlib.brotliDecompressSync(fs.readFileSync(path.join(dir, "index-abc.js.br"))).toString()).toBe(js);
    expect(fs.statSync(path.join(dir, "index-abc.js.br")).size).toBeLessThan(js.length / 10);
    expect(fs.existsSync(path.join(dir, "nested", "app.css.br"))).toBe(true);
    expect(fs.existsSync(path.join(dir, "tiny.js.gz"))).toBe(false);
    expect(fs.existsSync(path.join(dir, "logo.png.gz"))).toBe(false);
  });
});

describe("entry budget: what every page loads before anything shows", () => {
  const chunk = (fileName: string, isEntry: boolean, modules: Record<string, number>) => ({
    type: "chunk" as const,
    fileName,
    isEntry,
    code: "x".repeat(Object.values(modules).reduce((a, b) => a + b, 0)),
    modules: Object.fromEntries(Object.entries(modules).map(([id, renderedLength]) => [id, { renderedLength }])),
  });

  test("an entry over budget is refused, naming its heaviest modules; a lazy chunk does not count", () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "longx-budget-"));
    const bundle = {
      "index-a.js": chunk("index-a.js", true, { "/node_modules/elkjs/lib/elk.js": 2_000, "/js/app.tsx": 500 }),
      "mermaid-b.js": chunk("mermaid-b.js", false, { "/node_modules/beautiful-mermaid/x.js": 9_000 }),
    };
    const error = entryOverBudget(bundle, 2_000);
    expect(error).toMatch(/index-a\.js/);
    expect(error).toMatch(/2500/);
    expect(error).toMatch(/elkjs/);
    expect(entryOverBudget(bundle, 3_000)).toBeNull();
  });
});
