import { AlertTriangle, GitBranch, MemoryStick } from "lucide-react";
import { formatBytes, shortSha } from "@/core/format";
import { useFrame } from "@/core/frame";
import { useCodexInfo, useGitInfo, useSandboxStatus } from "@/core/projects";
import { t } from "@/ui/strings";
import type { ProjectContext } from "./ProjectWindow";

/** IDEA's status bar: HEAD, the codex process, memory, warnings. One thin line. */
export function StatusStrip({ ctx }: { ctx: ProjectContext }) {
  const git = useGitInfo(ctx.id);
  const codex = useCodexInfo(ctx.id);
  const sandbox = useSandboxStatus();
  const worker = codex.data?.worker as { phase?: string; active_turns?: number } | null | undefined;
  const rss = ctx.sample?.rss_bytes ?? (codex.data?.worker as { stats?: { rss_bytes: number } } | null)?.stats?.rss_bytes;
  const stale = codex.data?.stale ?? [];
  const frame = useFrame();

  return (
    <div className="bg-sidebar border-sidebar-border text-muted-foreground flex h-7 items-center gap-4 overflow-x-auto border-t px-3 text-xs" data-testid="status-strip">
      <span className="flex items-center gap-1 font-mono" title="HEAD">
        <GitBranch className="size-3" /> {git.data ? (git.data.repository ? shortSha(git.data.head) : "no git") : "…"}
        {git.data?.repository && !git.data.clean ? <span className="text-warning">·{git.data.changes}</span> : null}
      </span>
      <span className="flex items-center gap-1" title="codex">
        <span className={`size-2 rounded-full ${worker?.phase === "ready" ? "bg-success" : worker ? "bg-warning" : "bg-muted-foreground/50"}`} />
        {codex.data ? (worker ? (worker.active_turns ? "turn 进行中" : "codex 就绪") : "codex 未启动") : "…"}
      </span>
      {rss ? (
        <span className="flex items-center gap-1 font-mono" title="内存">
          <MemoryStick className="size-3" /> {formatBytes(rss)}
        </span>
      ) : null}
      {stale.length ? (
        <button type="button" className="text-warning flex items-center gap-1 hover:underline" title={t.codexStaleTitle} onClick={() => frame.open("process")}>
          <AlertTriangle className="size-3" /> {t.codexStale}
        </button>
      ) : null}
      {sandbox.data?.status === "unavailable" ? (
        <span className="text-warning flex items-center gap-1" title={sandbox.data.reason ?? ""}>
          <AlertTriangle className="size-3" /> 沙箱不可用
        </span>
      ) : null}
    </div>
  );
}
