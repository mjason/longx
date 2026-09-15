// Under a command the sandbox stopped: what the sandbox refused and one
// button that lets it through for this project — a writable directory, the
// network switch, the GPU devices — so nobody has to open the settings and
// type it in. Settings stay the place to take it back.
import { ShieldQuestion } from "lucide-react";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { updateProject } from "@/ash_rpc";
import { detectSandboxHint, type SandboxHint as Hint } from "@/core/chat/sandboxHints";
import type { CodexRuntime } from "@/core/chat/runtime";
import { queryKeys, sandboxPresets, unwrap, useProjects, useSandboxStatus } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";

const s = t.sandboxHint;

export function SandboxHint({ output, chat }: { output: string; chat: CodexRuntime }) {
  const client = useQueryClient();
  const sandbox = useSandboxStatus();
  const projects = useProjects();
  const project = projects.data?.find((p) => p.id === chat.projectId);
  const [state, setState] = useState<"idle" | "busy" | "done" | string>("idle");
  if (!project) return null;
  const presets = sandboxPresets(sandbox.data);
  const gpu = presets.find((p) => p.id === "gpu");
  const hint = detectSandboxHint(output, {
    sandbox: chat.mode.sandbox,
    networkAccess: chat.mode.networkAccess,
    home: sandbox.data?.home,
    gpu: !!gpu,
    writableRoots: project.writableRoots,
  });
  if (!hint) return null;

  const allow = async () => {
    setState("busy");
    try {
      const input = inputFor(hint, project, gpu?.paths ?? []);
      if (input) unwrap(await updateProject({ identity: project.id, fields: ["id"], input }));
      if (hint.kind === "network") chat.setMode({ ...chat.mode, networkAccess: true });
      await client.invalidateQueries({ queryKey: queryKeys.projects });
      await client.invalidateQueries({ queryKey: queryKeys.project(project.slug) });
      await client.invalidateQueries({ queryKey: queryKeys.codex(project.id) });
      setState("done");
    } catch (e) {
      setState(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="text-muted-foreground mt-2 flex flex-wrap items-center gap-2 text-xs" data-testid="sandbox-hint">
      <ShieldQuestion className="text-warning size-3.5 shrink-0" />
      <span>{message(hint)}</span>
      {hint.kind === "launch" ? null : state === "done" ? (
        <span className="text-success">{hint.kind === "gpu" ? s.allowedRestart : s.allowed}</span>
      ) : state === "idle" || state === "busy" ? (
        <Button size="sm" variant="outline" className="h-6 px-2 text-xs" disabled={state === "busy"} onClick={allow}>
          {s.allow}
        </Button>
      ) : (
        <span className="text-destructive">{s.failed(state)}</span>
      )}
    </div>
  );
}

function message(hint: Hint): string {
  switch (hint.kind) {
    case "writable":
      return s.writable(hint.dir);
    case "network":
      return s.network;
    case "gpu":
      return s.gpu;
    case "launch":
      return s.launch;
  }
}

function inputFor(hint: Hint, project: { writableRoots: string[]; passthroughPaths: string[] }, gpuPaths: string[]) {
  switch (hint.kind) {
    case "writable":
      return { writableRoots: [...project.writableRoots, hint.dir] };
    case "network":
      return { networkAccess: true };
    case "gpu":
      return { passthroughPaths: [...new Set([...project.passthroughPaths, ...gpuPaths])] };
    case "launch":
      return null;
  }
}
