// Build-time plugins for Vite (vite.config.ts): what reaches a browser on a
// weak network. Measured at 1.5 Mbps / 400 ms: the page's messages showed
// after 27 s, 21 of them the main script sent uncompressed — Plug.Static's
// `gzip:` only serves a `.gz` that sits beside a file, and nothing wrote one.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import type { Plugin } from "vite";

// text worth compressing; images and fonts are compressed already
const COMPRESSIBLE = /\.(js|mjs|css|html|json|svg|txt|map|wasm)$/;
// below this a compressed copy saves less than it costs (a header, a stat)
const MIN_BYTES = 1024;

/** Writes `<file>.gz` and `<file>.br` beside every compressible file under `dir`; the count of files done. */
export function compressDir(dir: string): number {
  let done = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      done += compressDir(file);
      continue;
    }
    if (!COMPRESSIBLE.test(entry.name)) continue;
    const data = fs.readFileSync(file);
    if (data.length < MIN_BYTES) continue;
    fs.writeFileSync(`${file}.gz`, zlib.gzipSync(data, { level: 9 }));
    fs.writeFileSync(
      `${file}.br`,
      zlib.brotliCompressSync(data, {
        params: {
          [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
          [zlib.constants.BROTLI_PARAM_SIZE_HINT]: data.length,
        },
      }),
    );
    done += 1;
  }
  return done;
}

/** The build output gets its .gz / .br copies (Plug.Static `gzip: true, brotli: true`). */
export function precompress(): Plugin {
  let outDir = "";
  return {
    name: "longx:precompress",
    apply: "build",
    configResolved(config) {
      outDir = path.resolve(config.root, config.build.outDir);
    },
    closeBundle() {
      compressDir(outDir);
    },
  };
}

type Chunkish = { type: string; fileName: string; isEntry?: boolean; code?: string; modules?: Record<string, { renderedLength: number }> };

/** Why the entry chunk is over `maxBytes` (its size and heaviest packages), or null when it is not. */
export function entryOverBudget(bundle: Record<string, Chunkish>, maxBytes: number): string | null {
  for (const chunk of Object.values(bundle)) {
    if (chunk.type !== "chunk" || !chunk.isEntry || !chunk.code) continue;
    const size = chunk.code.length;
    if (size <= maxBytes) continue;
    const byPackage = new Map<string, number>();
    for (const [id, m] of Object.entries(chunk.modules ?? {})) {
      const pkg = id.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/)?.[1] ?? "app";
      byPackage.set(pkg, (byPackage.get(pkg) ?? 0) + m.renderedLength);
    }
    const heaviest = [...byPackage.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8)
      .map(([pkg, n]) => `${pkg} ${Math.round(n / 1024)} KB`)
      .join(", ");
    return `the entry chunk ${chunk.fileName} is ${size} bytes, over its budget of ${maxBytes}: every page loads it before anything shows — load the heavy parts where they are used (import()). Heaviest: ${heaviest}`;
  }
  return null;
}

/** Fails the build when the entry chunk grows past `maxBytes`. */
export function entryBudget(maxBytes: number): Plugin {
  return {
    name: "longx:entry-budget",
    apply: "build",
    generateBundle(_options, bundle) {
      const error = entryOverBudget(bundle as unknown as Record<string, Chunkish>, maxBytes);
      if (error) this.error(error);
    },
  };
}

// Loaded on demand, never ahead of time: Shiki's grammars and themes (240 +
// 65 chunks, 1.3 MB compressed — a device needs a handful) and the diagram
// renderer (0.4 MB). What a page fetched once stays cached by the worker anyway.
const ON_DEMAND = new Set(["@shikijs/langs", "@shikijs/themes", "elkjs", "beautiful-mermaid", "mermaid"]);
// …except the code themes the chat draws with and the languages met every day
const AHEAD = /\/(github-(dark|light)-default|bash|shellscript|shell|json|jsonc|javascript|typescript|tsx|jsx|python|elixir|markdown|diff|yaml|toml|sql|go|rust|css|html|dockerfile)\.mjs$/;

function mainModule(modules: Record<string, { renderedLength: number }>): string {
  let best = "";
  let size = -1;
  for (const [id, m] of Object.entries(modules)) {
    if (m.renderedLength > size) {
      best = id;
      size = m.renderedLength;
    }
  }
  return best;
}

/** The files the service worker fetches at install, as URLs under `base`: the app, its stylesheets and the fonts a browser reads. */
export function precacheList(bundle: Record<string, Chunkish>, base: string): string[] {
  const urls: string[] = [];
  for (const item of Object.values(bundle)) {
    const name = item.fileName;
    if (name.startsWith(".vite/") || name.endsWith(".map")) continue;
    if (item.type === "chunk") {
      const main = mainModule(item.modules ?? {});
      const pkg = main.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/)?.[1];
      if (pkg && ON_DEMAND.has(pkg) && !AHEAD.test(main)) continue;
    } else if (/\.(woff|ttf|eot|otf)$/.test(name)) {
      continue; // every browser Longx runs in reads the woff2
    }
    urls.push(base + name);
  }
  return urls;
}

/**
 * Builds the service worker (js/sw/sw.ts) into `out` (priv/static/sw.js,
 * served at /sw.js so its scope is the whole page) with this build's
 * precache list and a version that sorts by build time — the worker keeps
 * its cache under that name and drops older builds'.
 */
export function serviceWorker(entry: string, out: string): Plugin {
  let root = "";
  let base = "/";
  return {
    name: "longx:service-worker",
    apply: "build",
    configResolved(config) {
      root = config.root;
      base = config.base;
    },
    async writeBundle(_options, bundle) {
      const urls = precacheList(bundle as unknown as Record<string, Chunkish>, base);
      const digest = crypto.createHash("sha256").update(urls.join("\n")).digest("hex").slice(0, 10);
      const version = `${Date.now().toString(36)}-${digest}`;
      // loaded here: esbuild refuses to load in the tests' jsdom
      const { build } = await import("esbuild");
      await build({
        entryPoints: [path.resolve(root, entry)],
        outfile: path.resolve(root, out),
        bundle: true,
        format: "iife",
        target: "es2020",
        minify: true,
        legalComments: "none",
        logLevel: "warning",
        define: { __PRECACHE__: JSON.stringify(urls), __VERSION__: JSON.stringify(version) },
      });
    },
  };
}
