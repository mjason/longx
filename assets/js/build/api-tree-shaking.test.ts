import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { describe, expect, test, vi } from "vitest";

const assets = process.cwd();
const execute = promisify(execFile);

async function selectedApi() {
  // esbuild runs in Node, not jsdom's substituted browser globals.
  const { stdout } = await execute(process.execPath, ["--input-type=module", "-e", `
    import { build } from "esbuild";
    const bundle = await build({
      stdin: {
        contents: 'export { listProjects } from "./js/core/api";',
        resolveDir: process.cwd(),
        loader: "ts",
      },
      alias: { "@": "./js" },
      bundle: true, write: false, minify: true, platform: "browser",
      format: "iife", globalName: "selectedApi",
    });
    process.stdout.write(bundle.outputFiles[0].text);
  `], { cwd: assets });
  return stdout;
}

describe("generated API entry loading", () => {
  test("an imported operation does not pull unused settings queries into the entry", async () => {
    const source = await selectedApi();
    expect(source.includes("query ListProjects")).toBe(true);
    expect(source.includes("query CommandGuardStatus")).toBe(false);
    expect(source.includes("query ListCredentials")).toBe(false);
  });

  test("creating the API does no I/O; invoking a retained operation still sends its document", async () => {
    const source = await selectedApi();
    const fetch = vi.fn().mockResolvedValue({
      ok: true,
      text: async () => JSON.stringify({ data: { listProjects: [] } }),
    });
    const api = new Function("fetch", `${source}; return selectedApi;`)(fetch);
    expect(fetch).not.toHaveBeenCalled();
    await expect(api.listProjects()).resolves.toEqual({ success: true, data: [] });
    expect(fetch).toHaveBeenCalledOnce();
    const [url, options] = fetch.mock.calls[0]!;
    expect(url).toBe("/gql");
    expect(JSON.parse(options.body).query).toContain("query ListProjects");
  });
});
