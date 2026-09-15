// The one thing codex's permission model cannot express: a device. A
// sandboxed command that cannot see the GPU (bwrap's minimal /dev) fails
// without any denial codex would ask about, so the chat says so and offers
// the project's device passthrough; CUDA also needs the network switch (the
// no-network seccomp catches the driver's local socket). Pure string
// matching on the output codex reports; DOM-free. Everything else — a
// directory, the network — the agent asks for through codex's own
// permission requests, which arrive as approval cards.

export type SandboxHint = { kind: "gpu" } | { kind: "cuda_network" };

export type SandboxContext = {
  sandbox: string;
  networkAccess: boolean;
  /** the machine has a GPU the sandbox hides (a `gpu` preset exists) */
  gpu?: boolean;
};

/** the GPU-related failure and its fix, or null */
export function detectSandboxHint(output: string, ctx: SandboxContext): SandboxHint | null {
  if (!output || ctx.sandbox === "danger_full_access" || !ctx.gpu) return null;
  if (!ctx.networkAccess && /CUDA_ERROR_OPERATING_SYSTEM/.test(output)) return { kind: "cuda_network" };
  // the words CUDA, JAX, PyTorch and nvidia-smi use when the device nodes are missing
  // (Linux: /dev/nvidia*; WSL2: /dev/dxg — there JAX fails on cuPTI first)
  if (/CUDA_ERROR_NO_DEVICE|NVIDIA-SMI has failed|Found no NVIDIA driver|Unable to load cuPTI|Unknown CUPTI error|no matches found: \/dev\/nvidia|\/dev\/(?:nvidia|dxg)[^\n]*No such file|GPU access blocked by the operating system/.test(output)) {
    return { kind: "gpu" };
  }
  return null;
}
