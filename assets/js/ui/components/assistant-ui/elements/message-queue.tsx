"use client";

// The registry's message-queue element (with a runtime), Longx's copy:
// what was typed while a turn runs, stacked above the composer until the
// turn ends — each row can be taken back, or inserted into the running
// turn right now (a steer), which the runtime does not offer itself.
import { ComposerPrimitive, QueueItemPrimitive, useAuiState } from "@assistant-ui/react";
import { ArrowDownToLineIcon, XIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { field, ghostButton, mono } from "@/ui/components/assistant-ui/elements/surfaces";

export function MessageQueue({
  onInsert,
  insertLabel,
  removeLabel,
  hint,
  className,
}: {
  onInsert?: (queueItemId: string) => void;
  insertLabel: string;
  removeLabel: string;
  hint: string;
  className?: string;
}) {
  const queueLength = useAuiState((s) => s.composer.queue.length);
  if (queueLength === 0) return null;

  return (
    <div className={cn("flex w-full flex-col gap-1.5 pb-2", className)} data-testid="message-queue">
      <span className={cn(mono, "text-foreground/35 px-1")}>{hint}</span>
      <ul className="flex flex-col gap-1.5">
        <ComposerPrimitive.Queue>
          {({ queueItem }) => (
            <li key={queueItem.id} className={cn(field, "flex items-center gap-2 rounded-2xl py-1.5 pr-1.5 pl-3")}>
              <span className="text-foreground/70 min-w-0 flex-1 truncate text-[13.5px]">
                <QueueItemPrimitive.Text />
              </span>
              {onInsert ? (
                <button
                  type="button"
                  className={cn(ghostButton, "h-6 shrink-0 gap-1 px-2 text-xs")}
                  onClick={() => onInsert(queueItem.id)}
                >
                  <ArrowDownToLineIcon className="size-3.5" /> {insertLabel}
                </button>
              ) : null}
              <QueueItemPrimitive.Remove aria-label={removeLabel} title={removeLabel} className={cn(ghostButton, "size-6 shrink-0")}>
                <XIcon className="size-3.5" />
              </QueueItemPrimitive.Remove>
            </li>
          )}
        </ComposerPrimitive.Queue>
      </ul>
    </div>
  );
}
