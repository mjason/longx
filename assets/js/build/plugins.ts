// Build-time plugins for Vite (vite.config.ts): what reaches a browser on a
// weak network. Measured at 1.5 Mbps / 400 ms: the page's messages showed
// after 27 s, 21 of them the main script sent uncompressed — Plug.Static's
// `gzip:` only serves a `.gz` that sits beside a file, and nothing wrote one.
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
