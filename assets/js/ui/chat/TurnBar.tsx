import { Loader2, ShieldAlert, ShieldCheck, ShieldOff } from "lucide-react";
import { Link, useOutletContext } from "react-router";
import type { TurnState } from "@/core/chat/runtime";
import { useModels } from "@/core/projects";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

// codex's reasoning efforts, one character each in the rail
const EFFORT: Record<string, string> = { minimal: "极低", low: "低", medium: "中", high: "高", xhigh: "极高" };

/**
 * Left of the composer rail (Codex's layout): the access mode the agent
 * runs with — a click goes to the project settings — and what the turn is
 * doing right now.
 */
export function ComposerLeading() {
  const ctx = useOutletContext<ProjectContext>();
  const { state } = useChat();
  const full = ctx.sandbox === "danger_full_access";
  const Icon = full ? ShieldOff : ctx.sandbox === "read_only" ? ShieldCheck : ShieldAlert;
  return (
    <div className="text-muted-foreground flex min-w-0 items-center gap-2 text-xs" data-testid="turn-bar">
      <Link
        to={`/p/${ctx.slug}/settings`}
        className={`flex items-center gap-1 rounded-md px-1.5 py-1 hover:bg-accent ${full ? "text-destructive" : ""}`}
        title={`${t.sandbox}: ${t.sandboxOptions[ctx.sandbox] ?? ctx.sandbox} · ${t.approval}: ${t.approvalOptions[ctx.approvalPolicy] ?? ctx.approvalPolicy}`}
      >
        <Icon className="size-3.5" />
        <span className="truncate">{t.sandboxOptions[ctx.sandbox] ?? ctx.sandbox}</span>
      </Link>
      {state === "running" ? (
        <span className="flex items-center gap-1">
          <Loader2 className="size-3.5 animate-spin" /> {t.turnRunning}
        </span>
      ) : state === "approval" ? (
        <span className="flex items-center gap-1 text-amber-600 dark:text-amber-400">
          <ShieldAlert className="size-3.5" /> {t.awaitingApproval}
        </span>
      ) : null}
    </div>
  );
}

/** Right of the rail, before send: the model the next turn uses (null = the thread's current). */
export function ComposerTrailing() {
  const { thread, model, setModel } = useChat();
  const models = useModels();
  const rows = models.data ?? [];
  const current = thread?.modelSlug ?? rows.find((m) => m.default)?.slug ?? null;
  const shown = rows.find((m) => m.slug === (model ?? current));
  const label = shown ? `${shown.slug}${shown.reasoningEffort ? ` ${EFFORT[shown.reasoningEffort] ?? shown.reasoningEffort}` : ""}` : (model ?? current ?? t.defaultModel);
  return (
    <Select value={model ?? "__current"} onValueChange={(v) => setModel(v === "__current" ? null : v)}>
      <SelectTrigger
        size="sm"
        aria-label={t.model}
        className="h-7 gap-1 border-0 bg-transparent px-2 font-mono text-xs shadow-none dark:bg-transparent dark:hover:bg-accent"
        data-testid="model-picker"
      >
        <SelectValue>{label}</SelectValue>
      </SelectTrigger>
      <SelectContent align="end">
        <SelectItem value="__current" className="font-mono text-xs">
          {current ?? t.defaultModel} <span className="text-muted-foreground ml-1 font-sans">{t.threadModel}</span>
        </SelectItem>
        {rows
          .filter((m) => m.slug)
          .map((m) => (
            <SelectItem key={m.id} value={m.slug!} className="font-mono text-xs">
              {m.slug}
              {m.reasoningEffort ? ` ${EFFORT[m.reasoningEffort] ?? m.reasoningEffort}` : ""}
              <span className="text-muted-foreground ml-1 font-sans">{providerName(m.provider)}</span>
            </SelectItem>
          ))}
      </SelectContent>
    </Select>
  );
}

function providerName(provider: unknown): string {
  return provider && typeof provider === "object" && "name" in provider ? String(provider.name) : "";
}
