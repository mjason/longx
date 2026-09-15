import { describe, expect, test } from "vitest";
import { detectSandboxHint, suggestWritableDir } from "./sandboxHints";

const ctx = { sandbox: "workspace_write", networkAccess: false, home: "/home/mj", gpu: true };

describe("detectSandboxHint", () => {
  test("a read-only write under the home → the tool's cache dir as ~", () => {
    const out = 'error: Could not acquire lock\n  Caused by: Could not create temporary file\n  Caused by: Read-only file system (os error 30) at path "/home/mj/.cache/uv/.tmpAUWL3u"\n';
    expect(detectSandboxHint(out, ctx)).toEqual({ kind: "writable", path: "/home/mj/.cache/uv/.tmpAUWL3u", dir: "~/.cache/uv" });
    expect(detectSandboxHint("touch: cannot touch '/home/mj/.npm/x': Read-only file system\n", ctx)).toEqual({ kind: "writable", path: "/home/mj/.npm/x", dir: "~/.npm" });
    // already allowed: nothing to offer
    expect(detectSandboxHint(out, { ...ctx, writableRoots: ["~/.cache/uv"] })).toBeNull();
  });

  test("CUDA's operating-system error / a refused connect → the network switch, unless it is on", () => {
    const out = "RuntimeError: jaxlib/cuda/versions_helpers.cc:135: operation cuInit(0) failed: CUDA_ERROR_OPERATING_SYSTEM\n";
    expect(detectSandboxHint(out, ctx)).toEqual({ kind: "network" });
    expect(detectSandboxHint("curl: (7) connect: Operation not permitted", ctx)).toEqual({ kind: "network" });
    expect(detectSandboxHint(out, { ...ctx, networkAccess: true })).toBeNull();
  });

  test("no device → the GPU passthrough, only on a machine with one", () => {
    const out = "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.";
    expect(detectSandboxHint(out, ctx)).toEqual({ kind: "gpu" });
    expect(detectSandboxHint("cuInit(0) failed: CUDA_ERROR_NO_DEVICE", ctx)).toEqual({ kind: "gpu" });
    expect(detectSandboxHint(out, { ...ctx, gpu: false })).toBeNull();
  });

  test("bwrap itself failing → the launch problem; full access never hints; plain failures stay quiet", () => {
    expect(detectSandboxHint("bwrap: setting up uid map: Permission denied", ctx)).toEqual({ kind: "launch" });
    expect(detectSandboxHint("bwrap: loopback: Failed RTM_NEWADDR", { ...ctx, sandbox: "danger_full_access" })).toBeNull();
    expect(detectSandboxHint("Traceback (most recent call last): KeyError: 'x'", ctx)).toBeNull();
    expect(detectSandboxHint("", ctx)).toBeNull();
  });
});

describe("suggestWritableDir", () => {
  test("home conventions and the fallback to the parent directory", () => {
    expect(suggestWritableDir("/home/mj/.cache/uv/.tmp1", "/home/mj")).toBe("~/.cache/uv");
    expect(suggestWritableDir("/home/mj/.cache/huggingface/hub/x/y", "/home/mj")).toBe("~/.cache/huggingface");
    expect(suggestWritableDir("/Users/mj/Library/Caches/pip/http/a", "/Users/mj")).toBe("~/Library/Caches/pip");
    expect(suggestWritableDir("/home/mj/.local/share/pnpm/store/v3", "/home/mj")).toBe("~/.local/share/pnpm");
    expect(suggestWritableDir("/home/mj/.npm/_cacache/x", "/home/mj/")).toBe("~/.npm");
    expect(suggestWritableDir("/home/mj/notes.txt", "/home/mj")).toBe("~/notes.txt");
    expect(suggestWritableDir("/data/models/x.bin", "/home/mj")).toBe("/data/models");
    expect(suggestWritableDir("/data/models/x.bin", null)).toBe("/data/models");
  });
});
