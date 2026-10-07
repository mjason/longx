import { useTranslation } from "react-i18next";
import { useEffect, useId, useState } from "react";
// What arrives from elsewhere while a turn runs — another agent's report or
// question, a session's message, a background job's end, a watch — waits for
// the turn to end, listed above the composer (never put in it: a stop once
// took back a turn a report had started and the report landed in the person's
// composer). 立即插入 sends one in now; after the person's stop the list says
// it waits for them.
import { ArrowDownToLineIcon, ChevronDownIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { field, ghostButton, mono } from "@/ui/components/assistant-ui/elements/surfaces";
import type { Waiting, WaitingMessage } from "@/core/chat/thread";
import { t } from "@/ui/strings";

function sender(m: WaitingMessage): string {
  if (m.source?.startsWith("job:")) return t.waitingJob(m.source.slice(4));
  if (m.mine) return t.waitingMine;
  return m.from ?? t.waitingFrom;
}

// the first line: a job's notice goes on with its command and its last lines
const firstLine = (text: string) => text.split("\n", 1)[0] ?? "";

export function WaitingMessagesView({ waiting, onRelease, onReleaseAll, busy = false }: {
  waiting: Waiting;
  onRelease: (id: string) => void;
  onReleaseAll?: () => void;
  busy?: boolean;
}) {
  useTranslation();
  const [open, setOpen] = useState(false);
  const listId = useId();
  useEffect(() => {
    if (waiting.items.length === 0) setOpen(false);
  }, [waiting.items.length]);
  if (waiting.items.length === 0) return null;
  const groups = new Map<string, WaitingMessage[]>();
  for (const item of waiting.items) {
    const key = item.mine ? "mine" : JSON.stringify([item.from ?? null, item.source ?? null]);
    const group = groups.get(key) ?? [];
    group.push(item);
    groups.set(key, group);
  }
  return (
    <div className="flex w-full flex-col gap-1.5 pb-2" data-testid="waiting-messages">
      <div className="flex items-center gap-2">
        <button type="button" aria-expanded={open} aria-controls={listId} title={waiting.paused ? t.waitingPaused : t.waitingHint}
          className={cn(ghostButton, "min-w-0 flex-1 justify-start gap-1.5 px-2 py-1 text-xs")}
          onClick={() => setOpen((value) => !value)}>
          <ChevronDownIcon aria-hidden className={cn("size-3.5 shrink-0 transition-transform", !open && "-rotate-90")} />
          <span className="truncate">{t.waitingCount(waiting.items.length)}</span>
        </button>
        {onReleaseAll && <button type="button" disabled={busy} className={cn(ghostButton, "shrink-0 gap-1 px-2 py-1 text-xs")} onClick={onReleaseAll}>
          <ArrowDownToLineIcon aria-hidden className="size-3.5" /> {t.waitingInsertAll}
        </button>}
      </div>
      {(open || waiting.paused) && <span className={cn(mono, "px-2 text-xs", waiting.paused ? "text-warning" : "text-foreground/35")}>
        {waiting.paused ? t.waitingPaused : t.waitingHint}
      </span>}
      {open && <div id={listId} className="max-h-64 space-y-2 overflow-y-auto overscroll-contain">
        {[...groups].map(([key, messages]) => <section key={key} data-testid="waiting-group">
          <div className={cn(mono, "truncate px-2 pb-1 text-xs text-foreground/45")}>{sender(messages[0]!)} · {messages.length}</div>
          <ul className="flex flex-col gap-1.5">
        {messages.map((m) => {
          const kind = m.kind ? t.agentMessageKind[m.kind] : undefined;
          return (
            <li key={m.id} data-testid="waiting-message" className={cn(field, "flex items-center gap-2 rounded-2xl border-dashed py-1.5 pr-1.5 pl-3")}>
              <span className={cn(mono, "text-foreground/55 max-w-28 shrink-0 truncate text-xs")} title={sender(m)}>
                {sender(m)}
                {kind ? ` · ${kind}` : ""}
              </span>
              <details className="text-foreground/70 min-w-0 flex-1 text-[13.5px]">
                <summary className="cursor-pointer truncate" title={m.text}>{firstLine(m.text)}</summary>
                <p className="max-h-40 overflow-y-auto whitespace-pre-wrap break-words py-2">{m.text}</p>
              </details>
              <button type="button" disabled={busy} className={cn(ghostButton, "h-6 shrink-0 gap-1 px-2 text-xs")} onClick={() => onRelease(m.id)}>
                <ArrowDownToLineIcon className="size-3.5" /> {t.waitingInsert}
              </button>
            </li>
          );
        })}
          </ul>
        </section>)}
      </div>}
    </div>
  );
}
