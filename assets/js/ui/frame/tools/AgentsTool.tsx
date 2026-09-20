import { useParams } from "react-router";
import { relativeTime } from "@/core/format";
import { useSubagents } from "@/core/projects";
import { useWorkbench } from "@/core/workbench";
import { BackgroundInbox, type BackgroundRun } from "@/ui/components/assistant-ui/elements/background-inbox";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";
import { agentSummaries } from "@/ui/chat/AgentsPanel";
import { useChatMaybe } from "@/ui/chat/ChatProvider";
import type { ProjectContext } from "../ProjectWindow";
import { SessionDirectory } from "./SessionDirectory";

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
  return (
    <div className="flex flex-col gap-4" data-testid="agents-tool">
      <Subagents ctx={ctx} />
      <SessionDirectory projectId={ctx.id} slug={ctx.slug} />
    </div>
  );
}

function Subagents({ ctx }: { ctx: ProjectContext }) {
  const { threadId } = useParams();
  const workbench = useWorkbench(ctx.id);
  const subagents = useSubagents(threadId);
  // what each child does right now, from the live views the chat follows
  const chat = useChatMaybe();
  const live = chat ? agentSummaries(chat.view, chat.subviews) : [];

  if (!threadId) return <p className="text-muted-foreground text-sm">{t.pickThread}</p>;
  if (subagents.isPending) return <Skeleton className="h-16 w-full" />;
  if (subagents.isError) return <p className="text-destructive text-sm">{subagents.error.message}</p>;
  if (subagents.data.length === 0) return <p className="text-muted-foreground text-sm">{t.noSubagents}</p>;

  const runs: BackgroundRun[] = subagents.data.map((row) => {
    const now = live.find((a) => a.threadId === row.kernelThreadId);
    return {
      id: row.id,
      title: row.title ?? row.agentPath ?? row.kernelThreadId,
      state: now ? (now.state === "done" ? "ready" : "running") : stateOf(row.status),
      elapsed: relativeTime(row.lastActivityAt),
      summary: now && now.state !== "done" ? now.label : (now?.excerpt ?? row.preview ?? row.agentPath ?? row.kernelThreadId),
    };
  });

  return (
    <div className="flex flex-col gap-2">
      <BackgroundInbox runs={runs} title={t.subagentsTitle} countLabel={t.subagentsCount} onCollect={(id) => {
          // its conversation opens beside the chat; the row's page stays a link away
          const row = subagents.data.find((r) => r.id === id);
          if (row) workbench.open({ kind: "agent", threadId: row.kernelThreadId, rowId: row.id, name: row.title ?? row.agentPath ?? row.kernelThreadId });
        }} className="max-w-none" />
      <p className="text-muted-foreground text-xs">{t.subagentsHint}</p>
    </div>
  );
}
