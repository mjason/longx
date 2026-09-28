import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { afterEach, describe, expect, test } from "vitest";
import { compressDir, entryOverBudget, precacheList } from "./plugins";

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

describe("the service worker's precache: what a device fetches ahead of time", () => {
  const chunk = (fileName: string, modules: Record<string, number>) => ({
    type: "chunk" as const,
    fileName,
    isEntry: false,
    code: "",
    modules: Object.fromEntries(Object.entries(modules).map(([id, renderedLength]) => [id, { renderedLength }])),
  });
  const asset = (fileName: string) => ({ type: "asset" as const, fileName });

  test("the app's chunks, the stylesheets, KaTeX's woff2 and the two code themes; not every grammar, theme or the diagram renderer", () => {
    const bundle = {
      a: chunk("index-A1.js", { "/app/js/index.tsx": 900, "/app/node_modules/react/index.js": 100 }),
      b: chunk("EditorTab-B2.js", { "/app/js/ui/workbench/EditorTab.tsx": 50 }),
      c: chunk("elixir-C3.js", { "/app/node_modules/@shikijs/langs/dist/elixir.mjs": 40 }),
      d: chunk("cobol-D4.js", { "/app/node_modules/@shikijs/langs/dist/cobol.mjs": 40 }),
      e: chunk("github-dark-default-E5.js", { "/app/node_modules/@shikijs/themes/dist/github-dark-default.mjs": 10 }),
      f: chunk("dracula-F6.js", { "/app/node_modules/@shikijs/themes/dist/dracula.mjs": 10 }),
      g: chunk("elk-G7.js", { "/app/node_modules/elkjs/lib/elk.bundled.js": 1000, "/app/js/x.ts": 1 }),
      h: chunk("mermaid-H8.js", { "/app/node_modules/beautiful-mermaid/dist/index.js": 300 }),
      i: asset("index-I9.css"),
      j: asset("KaTeX_Main-Regular-J1.woff2"),
      k: asset("KaTeX_Main-Regular-K2.woff"),
      l: asset("KaTeX_Main-Regular-L3.ttf"),
      m: asset(".vite/manifest.json"),
      n: asset("index-A1.js.map"),
    };
    expect(precacheList(bundle, "/assets/")).toEqual([
      "/assets/index-A1.js",
      "/assets/EditorTab-B2.js",
      "/assets/elixir-C3.js",
      "/assets/github-dark-default-E5.js",
      "/assets/index-I9.css",
      "/assets/KaTeX_Main-Regular-J1.woff2",
    ]);
  });
});
