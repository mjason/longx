import { AlertTriangle, ArrowUpCircle, GitBranch, MemoryStick } from "lucide-react";
import { Link } from "react-router";
import { formatBytes, shortSha } from "@/core/format";
import { useFrame } from "@/core/frame";
import { useCodexInfo, useGitInfo, useSandboxStatus } from "@/core/projects";
import { useUpgradeStatus } from "@/core/upgrade";
import { t } from "@/ui/strings";
import type { ProjectContext } from "./ProjectWindow";

const item = (extra = "") => `flex shrink-0 items-center gap-1 whitespace-nowrap ${extra}`;

/** IDEA's status bar: HEAD, the codex process, memory, warnings. One thin line. */
export function StatusStrip({ ctx }: { ctx: ProjectContext }) {
  const git = useGitInfo(ctx.id);
  const codex = useCodexInfo(ctx.id);
  const sandbox = useSandboxStatus();
  const upgrade = useUpgradeStatus({ poll: false });
  const worker = codex.data?.worker as { phase?: string; active_turns?: number } | null | undefined;
  const rss = ctx.sample?.rss_bytes ?? (codex.data?.worker as { stats?: { rss_bytes: number } } | null)?.stats?.rss_bytes;
  const stale = codex.data?.stale ?? [];
  const frame = useFrame();

  return (
    // every item stays on one line: a narrow phone scrolls the strip sideways
    // instead of folding "codex 就绪" into two rows
    <div className="bg-sidebar border-sidebar-border text-muted-foreground flex h-7 items-center gap-4 overflow-x-auto border-t px-3 text-xs" data-testid="status-strip">
      <span className={item("font-mono")} title="HEAD">
        <GitBranch className="size-3" /> {git.data ? (git.data.repository ? shortSha(git.data.head) : "no git") : "…"}
        {git.data?.repository && !git.data.clean ? <span className="text-warning">·{git.data.changes}</span> : null}
      </span>
      {ctx.engine === "native" ? (
        // no codex process behind a native project: the strip names the kernel
        <span className={item()} title={t.engine}>
          <span className="bg-success size-2 rounded-full" /> {t.engineNativeShort}
        </span>
      ) : (
        <span className={item()} title="codex">
          <span className={`size-2 rounded-full ${worker?.phase === "ready" ? "bg-success" : worker ? "bg-warning" : "bg-muted-foreground/50"}`} />
          {codex.data ? (worker ? (worker.active_turns ? "turn 进行中" : "codex 就绪") : "codex 未启动") : "…"}
        </span>
      )}
      {rss ? (
        <span className={item("font-mono")} title="内存">
          <MemoryStick className="size-3" /> {formatBytes(rss)}
        </span>
      ) : null}
      {stale.length ? (
        <button type="button" className={item("text-warning hover:underline")} title={t.codexStaleTitle} onClick={() => frame.open("process")}>
          <AlertTriangle className="size-3" /> {t.codexStale}
        </button>
      ) : null}
      {upgrade.data?.available && upgrade.data.latest ? (
        <Link to="/settings/update" className={item("text-primary hover:underline")} title={t.updatePage.hint}>
          <ArrowUpCircle className="size-3" /> {t.updatePage.newVersion(upgrade.data.latest)}
        </Link>
      ) : null}
      {sandbox.data && sandbox.data.status !== "ok" ? (
        <span className={item("text-warning")} title={sandbox.data.reason ?? ""}>
          <AlertTriangle className="size-3" /> {sandbox.data.status === "no_net_isolation" ? "沙箱不隔离网络" : "沙箱不可用"}
        </span>
      ) : null}
    </div>
  );
}
