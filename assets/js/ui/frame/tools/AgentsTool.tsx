import { useNavigate, useParams } from "react-router";
import { relativeTime } from "@/core/format";
import { useSubagents } from "@/core/projects";
import { BackgroundInbox, type BackgroundRun } from "@/ui/components/assistant-ui/elements/background-inbox";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";
import type { ProjectContext } from "../ProjectWindow";

// a sub-agent thread's status as a background run: still working, done
// (its thread can be opened), or gone
function stateOf(status: string): BackgroundRun["state"] {
  if (status === "active" || status === "disconnected") return "running";
  if (status === "idle") return "ready";
  return "failed";
}

/**
 * The sub-agents spawned in this thread, as assistant-ui's background
 * inbox: each is a thread of its own under the parent; a finished one opens
 * like any thread, with its full conversation.
 */
export function AgentsTool({ ctx }: { ctx: ProjectContext }) {
  const { threadId } = useParams();
  const navigate = useNavigate();
  const subagents = useSubagents(threadId);

  if (!threadId) return <p className="text-muted-foreground text-sm">{t.pickThread}</p>;
  if (subagents.isPending) return <Skeleton className="h-16 w-full" />;
  if (subagents.isError) return <p className="text-destructive text-sm">{subagents.error.message}</p>;
  if (subagents.data.length === 0) return <p className="text-muted-foreground text-sm">{t.noSubagents}</p>;

  const runs: BackgroundRun[] = subagents.data.map((row) => ({
    id: row.id,
    title: row.title ?? row.agentPath ?? row.kernelThreadId,
    state: stateOf(row.status),
    elapsed: relativeTime(row.lastActivityAt),
    summary: row.preview ?? row.agentPath ?? row.kernelThreadId,
  }));

  return (
    <div className="flex flex-col gap-2" data-testid="agents-tool">
      <BackgroundInbox runs={runs} title={t.subagentsTitle} countLabel={t.subagentsCount} onCollect={(id) => navigate(`/p/${ctx.slug}/t/${id}`)} className="max-w-none" />
      <p className="text-muted-foreground text-xs">{t.subagentsHint}</p>
    </div>
  );
}
