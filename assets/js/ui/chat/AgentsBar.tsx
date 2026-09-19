// The children at work, named at the top of the page whatever is scrolled
// into view: their rows sit wherever they were spawned in the transcript,
// and a long session hid who was still working. One chip per working or
// waiting child — its state, what its model is writing, 打开 for its tab,
// 停止 — gone when nobody works.
import { Bot, ShieldAlert, Square } from "lucide-react";
import { useContext, useState } from "react";
import { toast } from "sonner";
import { ACTION_REQUEST, subagentsOf } from "@/core/chat/messages";
import { runningTurnId, type ThreadView } from "@/core/chat/thread";
import { formatBytes } from "@/core/format";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";
import { SubagentContext } from "./toolkit";

type Working = { threadId: string; name: string; waiting: string | null; doing: string };

/** the children with a turn in flight or an ask pending, from the parent's view and theirs */
export function workingAgents(view: ThreadView, subviews: Record<string, ThreadView>): Working[] {
  const out: Working[] = [];
  for (const agent of subagentsOf(view).values()) {
    const sub = subviews[agent.threadId];
    if (!sub) continue;
    const pending = sub.requests.find((r) => r.method === ACTION_REQUEST);
    const running = runningTurnId(sub) !== null;
    if (!pending && !running) continue;
    const progress = sub.progress;
    const doing =
      progress?.kind === "retry"
        ? t.turnRetrying(progress.name)
        : progress?.kind === "toolCall"
          ? t.turnWriting(progress.name, formatBytes(progress.bytes))
          : t.subagentState["interacted"]!;
    out.push({
      threadId: agent.threadId,
      name: agent.name,
      waiting: pending ? String(pending.params["title"] ?? t.subagentNeedsAction) : null,
      doing,
    });
  }
  return out;
}

export function AgentsBar() {
  const { view, subviews } = useChat();
  const subagents = useContext(SubagentContext);
  const [stopping, setStopping] = useState<string | null>(null);
  const working = workingAgents(view, subviews);
  if (working.length === 0) return null;

  const stop = async (threadId: string) => {
    if (!subagents) return;
    setStopping(threadId);
    try {
      await subagents.stop(threadId);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setStopping(null);
    }
  };

  return (
    <div className="border-b px-3 py-1.5" data-testid="agents-bar">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
        <span className="text-muted-foreground shrink-0">{t.agentsAtWork(working.length)}</span>
        {working.map((w) => (
          <span key={w.threadId} className="bg-muted flex min-w-0 items-center gap-1.5 rounded-full py-0.5 ps-2 pe-1">
            {w.waiting ? (
              <ShieldAlert className="size-3.5 shrink-0 text-amber-600 dark:text-amber-400" aria-hidden />
            ) : (
              <Bot className="text-foreground/55 size-3.5 shrink-0" aria-hidden />
            )}
            <button
              type="button"
              className="flex min-w-0 items-center gap-1.5 hover:underline"
              onClick={() => subagents?.open(w.threadId, w.name)}
              title={t.openSubagent}
            >
              <code className="font-mono">{w.name}</code>
              <span className={`truncate ${w.waiting ? "text-amber-600 dark:text-amber-400" : "text-muted-foreground"}`}>
                {w.waiting ?? w.doing}
              </span>
            </button>
            {subagents && !w.waiting ? (
              <Button
                size="icon"
                variant="ghost"
                className="size-5"
                aria-label={`${t.stopSubagent} ${w.name}`}
                disabled={stopping === w.threadId}
                onClick={() => void stop(w.threadId)}
              >
                <Square className="size-3" />
              </Button>
            ) : null}
          </span>
        ))}
      </div>
    </div>
  );
}
