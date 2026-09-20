// Who is working for this session, wherever the page is scrolled: the
// children's rows sit where they were spawned in the transcript, and a long
// session hid who was still at work. On a desktop a card floats at the
// chat's top right (folded to a pill when the person prefers, the choice
// kept on the device): the children with a turn in flight or an ask
// waiting, then the last few finished; a click opens a child's tab, ■ stops
// it. On a phone the same knowledge is a pill that opens the Agent sheet,
// whose inbox says what each child does.
import { Bot, ChevronDown, ShieldAlert, Square } from "lucide-react";
import { useContext, useState } from "react";
import { toast } from "sonner";
import { ACTION_REQUEST, subagentsOf } from "@/core/chat/messages";
import { runningTurnId, type ThreadView } from "@/core/chat/thread";
import { formatBytes } from "@/core/format";
import { useFrame } from "@/core/frame";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";
import { SubagentContext } from "./toolkit";

export type AgentSummary = {
  threadId: string;
  name: string;
  state: "working" | "waiting" | "done";
  /** what to say beside the name: the ask's title, what the model writes, or the last state */
  label: string;
  /** the child's last words, for the inbox */
  excerpt: string | null;
};

/** every child the view mentions, with its live state from its own view */
export function agentSummaries(view: ThreadView, subviews: Record<string, ThreadView>): AgentSummary[] {
  const out: AgentSummary[] = [];
  for (const agent of subagentsOf(view).values()) {
    const sub = subviews[agent.threadId];
    const pending = sub?.requests.find((r) => r.method === ACTION_REQUEST);
    const running = sub ? runningTurnId(sub) !== null : agent.kind === "started" || agent.kind === "interacted";
    const progress = sub?.progress;
    const doing =
      progress?.kind === "retry"
        ? t.turnRetrying(progress.name)
        : progress?.kind === "toolCall"
          ? t.turnWriting(progress.name, formatBytes(progress.bytes))
          : t.subagentState["interacted"]!;
    const state: AgentSummary["state"] = pending ? "waiting" : running ? "working" : "done";
    out.push({
      threadId: agent.threadId,
      name: agent.name,
      state,
      label: pending ? String(pending.params["title"] ?? t.subagentNeedsAction) : running ? doing : (t.subagentState[agent.kind] ?? agent.kind),
      excerpt: sub ? lastWords(sub) : null,
    });
  }
  return out;
}

function lastWords(view: ThreadView): string | null {
  for (let i = view.items.length - 1; i >= 0; i -= 1) {
    const item = view.items[i]!;
    if (item.type === "agentMessage" && typeof item["text"] === "string" && (item["text"] as string).trim()) {
      const text = (item["text"] as string).trim().replace(/\s+/g, " ");
      return text.length > 120 ? text.slice(0, 120) + "…" : text;
    }
  }
  return null;
}

const FOLDED_KEY = "longx:agents-panel-folded";
const RECENT_DONE = 5;

function useFolded(): [boolean, (v: boolean) => void] {
  const [folded, setFolded] = useState(() => {
    try {
      return localStorage.getItem(FOLDED_KEY) === "1";
    } catch {
      return false;
    }
  });
  return [
    folded,
    (v) => {
      setFolded(v);
      try {
        localStorage.setItem(FOLDED_KEY, v ? "1" : "0");
      } catch {
        // a private window: not remembered
      }
    },
  ];
}

function useActive() {
  const { view, subviews } = useChat();
  const all = agentSummaries(view, subviews);
  const active = all.filter((a) => a.state !== "done");
  const done = all.filter((a) => a.state === "done").slice(-RECENT_DONE).reverse();
  return { active, done };
}

/** the floating card, a desktop's */
export function AgentsPanel() {
  const { active, done } = useActive();
  const subagents = useContext(SubagentContext);
  const [folded, setFolded] = useFolded();
  const [stopping, setStopping] = useState<string | null>(null);
  if (active.length === 0 && done.length === 0) return null;
  const waiting = active.filter((a) => a.state === "waiting").length;

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

  if (folded) {
    return (
      <div className="absolute end-4 top-3 z-10" data-testid="agents-panel">
        <Pill active={active.length} waiting={waiting} onClick={() => setFolded(false)} />
      </div>
    );
  }

  const row = (a: AgentSummary) => (
    <li key={a.threadId} className="flex items-center gap-1.5">
      {a.state === "waiting" ? (
        <ShieldAlert className="size-3.5 shrink-0 text-amber-600 dark:text-amber-400" aria-hidden />
      ) : (
        <Bot className={`size-3.5 shrink-0 ${a.state === "working" ? "text-primary" : "text-foreground/40"}`} aria-hidden />
      )}
      <button type="button" className="flex min-w-0 flex-1 items-center gap-1.5 text-start hover:underline" onClick={() => subagents?.open(a.threadId, a.name)} title={t.openSubagent}>
        <code className={`shrink-0 font-mono ${a.state === "done" ? "text-muted-foreground" : ""}`}>{a.name}</code>
        <span className={`min-w-0 truncate ${a.state === "waiting" ? "text-amber-600 dark:text-amber-400" : "text-muted-foreground"}`}>{a.label}</span>
      </button>
      {subagents && a.state === "working" ? (
        <Button size="icon" variant="ghost" className="size-5 shrink-0" aria-label={`${t.stopSubagent} ${a.name}`} disabled={stopping === a.threadId} onClick={() => void stop(a.threadId)}>
          <Square className="size-3" />
        </Button>
      ) : null}
    </li>
  );

  return (
    <div className="bg-popover text-popover-foreground absolute end-4 top-3 z-10 w-72 rounded-xl border p-3 text-xs shadow-md" data-testid="agents-panel">
      <div className="mb-2 flex items-center justify-between">
        <span className="font-medium">{t.agentsPanel.title}</span>
        <button type="button" className="text-muted-foreground hover:text-foreground rounded p-0.5" aria-label={t.agentsPanel.fold} onClick={() => setFolded(true)}>
          <ChevronDown className="size-4" />
        </button>
      </div>
      {active.length > 0 ? <ul className="flex flex-col gap-1.5">{active.map(row)}</ul> : <p className="text-muted-foreground">{t.agentsPanel.nobody}</p>}
      {done.length > 0 ? (
        <>
          <div className="text-muted-foreground mt-3 mb-1.5 border-t pt-2">{t.agentsPanel.recentlyDone}</div>
          <ul className="flex flex-col gap-1.5">{done.map(row)}</ul>
        </>
      ) : null}
    </div>
  );
}

function Pill({ active, waiting, onClick }: { active: number; waiting: number; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`bg-popover flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs shadow-md ${waiting > 0 ? "border-amber-500/60 text-amber-600 dark:text-amber-400" : "text-foreground"}`}
    >
      {waiting > 0 ? <ShieldAlert className="size-3.5" aria-hidden /> : <Bot className="size-3.5" aria-hidden />}
      <span>{waiting > 0 ? t.agentsPanel.waitingCount(waiting) : t.agentsPanel.workingCount(active)}</span>
    </button>
  );
}

/** the phone's pill: a count, opening the Agent sheet */
export function AgentsPill() {
  const { active } = useActive();
  const frame = useFrame();
  if (active.length === 0) return null;
  const waiting = active.filter((a) => a.state === "waiting").length;
  return (
    <div className="absolute end-3 top-2 z-10" data-testid="agents-pill">
      <Pill active={active.length} waiting={waiting} onClick={() => frame.open("agents")} />
    </div>
  );
}
