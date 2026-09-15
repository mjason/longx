import { describe, expect, test } from "vitest";
import { detectSandboxHint } from "./sandboxHints";

const ctx = { sandbox: "workspace_write", networkAccess: false, gpu: true };

describe("detectSandboxHint (GPU only — everything else is codex's own permission request)", () => {
  test("no device in the sandbox → the passthrough, only on a machine with a GPU", () => {
    expect(detectSandboxHint("NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.", ctx)).toEqual({ kind: "gpu" });
    expect(detectSandboxHint("cuInit(0) failed: CUDA_ERROR_NO_DEVICE", ctx)).toEqual({ kind: "gpu" });
    expect(detectSandboxHint("Failed to initialize NVML: GPU access blocked by the operating system", ctx)).toEqual({ kind: "gpu" });
    expect(detectSandboxHint("RuntimeError: Found no NVIDIA driver on your system.", ctx)).toEqual({ kind: "gpu" });
    // WSL2 without /dev/dxg: JAX trips on cuPTI before it ever asks for a device
    expect(detectSandboxHint("operation cuptiGetVersion(&version) failed: Unknown CUPTI error 2. This probably means that JAX was unable to load cupti.", ctx)).toEqual({ kind: "gpu" });
    expect(detectSandboxHint("cuInit(0) failed: CUDA_ERROR_NO_DEVICE", { ...ctx, gpu: false })).toBeNull();
  });

  test("full access never hints; a read-only path is codex's business now; plain failures stay quiet", () => {
    expect(detectSandboxHint("CUDA_ERROR_NO_DEVICE", { ...ctx, sandbox: "danger_full_access" })).toBeNull();
    expect(detectSandboxHint('Read-only file system (os error 30) at path "/home/mj/.cache/uv/.tmp"', ctx)).toBeNull();
    expect(detectSandboxHint("KeyError: 'x'", ctx)).toBeNull();
    expect(detectSandboxHint("", ctx)).toBeNull();
  });
});
