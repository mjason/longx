// What a sandboxed command's failure output says about the sandbox, and the
// one setting that would let it through — so the chat can offer "允许"
// instead of the model guessing (a read-only cache, a device the sandbox
// hides, the driver's local socket caught by the no-network seccomp). Pure
// string matching on the output codex reports; DOM-free. Signatures are the
// Linux / macOS ones (verified on Linux); Windows outputs are not matched.

export type SandboxHint =
  | { kind: "writable"; path: string; dir: string }
  | { kind: "network" }
  | { kind: "gpu" }
  | { kind: "launch" };

export type SandboxContext = {
  sandbox: string;
  networkAccess: boolean;
  /** the server user's home, to shorten paths under it to ~ */
  home?: string | null;
  /** the machine has a GPU the sandbox hides (a `gpu` preset exists) */
  gpu?: boolean;
  /** paths the project already lets in / writes — a hint never repeats one */
  writableRoots?: string[];
};

const READ_ONLY = /Read-only file system(?:[^\n]*?(?:at path|:)\s*["']?([^"'\n]+?)["']?)?(?=\n|$)/;
const CANNOT = /(?:cannot (?:touch|create|open|access|write)[^'"\n]*|Permission denied[^'"\n]*)['"]([^'"\n]+)['"][^\n]*Read-only file system/;

/** the failure kind and its fix, or null when the output shows no sandbox limit */
export function detectSandboxHint(output: string, ctx: SandboxContext): SandboxHint | null {
  if (!output || ctx.sandbox === "danger_full_access") return null;
  if (/^bwrap: /m.test(output)) return { kind: "launch" };

  const ro = CANNOT.exec(output) ?? READ_ONLY.exec(output);
  if (ro) {
    const path = ro[1]?.trim();
    if (path && path.startsWith("/")) {
      const dir = suggestWritableDir(path, ctx.home ?? null);
      if (!(ctx.writableRoots ?? []).includes(dir)) return { kind: "writable", path, dir };
    }
  }

  if (!ctx.networkAccess && /CUDA_ERROR_OPERATING_SYSTEM|connect(?:\(\))?: Operation not permitted|EPERM[^\n]*connect/.test(output)) {
    return { kind: "network" };
  }

  if (ctx.gpu && /CUDA_ERROR_NO_DEVICE|NVIDIA-SMI has failed|no matches found: \/dev\/nvidia|\/dev\/nvidia[^\n]*No such file/.test(output)) {
    return { kind: "gpu" };
  }

  return null;
}

/**
 * The directory to allow for a denied write: under the home's cache
 * conventions the tool's own cache dir (`~/.cache/uv`, `~/Library/Caches/pip`,
 * `~/.npm`), otherwise the file's directory; `~` when under the home.
 */
export function suggestWritableDir(path: string, home: string | null): string {
  const h = home?.replace(/\/$/, "");
  if (h && (path === h || path.startsWith(h + "/"))) {
    const rel = path.slice(h.length + 1).split("/").filter(Boolean);
    // how deep a tool's own directory sits: ~/.cache/<tool>, ~/Library/Caches/<tool>,
    // ~/.local/share/<tool>, ~/.cargo/registry, ~/.gradle/caches, ~/.m2/repository, else ~/<dir>
    const depth: Record<string, number> = { ".cache": 2, Library: 3, ".local": 3, ".cargo": 2, ".gradle": 2, ".m2": 2 };
    const keep = depth[rel[0] ?? ""] ?? 1;
    const segs = rel.slice(0, Math.min(keep, Math.max(rel.length - 1, 1)));
    return "~/" + segs.join("/");
  }
  const i = path.lastIndexOf("/");
  return i > 0 ? path.slice(0, i) : path;
}
