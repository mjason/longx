// What arrives from elsewhere while a turn runs — another agent's report or
// question, a session's message, a background job's end, a watch — waits for
// the turn to end, listed above the composer (never put in it: a stop once
// took back a turn a report had started and the report landed in the person's
// composer). 立即插入 sends one in now; after the person's stop the list says
// it waits for them.
import { ArrowDownToLineIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { field, ghostButton, mono } from "@/ui/components/assistant-ui/elements/surfaces";
import type { Waiting, WaitingMessage } from "@/core/chat/thread";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

function sender(m: WaitingMessage): string {
  if (m.source?.startsWith("job:")) return t.waitingJob(m.source.slice(4));
  return m.from ?? t.waitingFrom;
}

// the first line: a job's notice goes on with its command and its last lines
const firstLine = (text: string) => text.split("\n", 1)[0] ?? "";

export function WaitingMessagesView({ waiting, onRelease }: { waiting: Waiting; onRelease: (id: string) => void }) {
  if (waiting.items.length === 0) return null;
  return (
    <div className="flex w-full flex-col gap-1.5 pb-2" data-testid="waiting-messages">
      <span className={cn(mono, "px-1", waiting.paused ? "text-warning" : "text-foreground/35")}>
        {waiting.paused ? t.waitingPaused : t.waitingHint}
      </span>
      <ul className="flex flex-col gap-1.5">
        {waiting.items.map((m) => {
          const kind = m.kind ? t.agentMessageKind[m.kind] : undefined;
          return (
            <li key={m.id} data-testid="waiting-message" className={cn(field, "flex items-center gap-2 rounded-2xl border-dashed py-1.5 pr-1.5 pl-3")}>
              <span className={cn(mono, "text-foreground/55 shrink-0 text-xs")}>
                {sender(m)}
                {kind ? ` · ${kind}` : ""}
              </span>
              <span className="text-foreground/70 min-w-0 flex-1 truncate text-[13.5px]" title={m.text}>
                {firstLine(m.text)}
              </span>
              <button type="button" className={cn(ghostButton, "h-6 shrink-0 gap-1 px-2 text-xs")} onClick={() => onRelease(m.id)}>
                <ArrowDownToLineIcon className="size-3.5" /> {t.waitingInsert}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

/** The thread on screen's waiting list (ChatProvider's view). */
export function WaitingMessages() {
  const { view, releaseWaiting } = useChat();
  return <WaitingMessagesView waiting={view.waiting} onRelease={(id) => void releaseWaiting(id)} />;
}
