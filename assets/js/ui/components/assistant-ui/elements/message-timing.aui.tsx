"use client";

import { useMessageTiming } from "@assistant-ui/react";
import { t } from "@/ui/strings";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/ui/components/ui/tooltip";
import { cn } from "@/lib/utils";
import type { FC } from "react";

const formatTimingMs = (ms: number | undefined): string => {
  if (ms === undefined) return "—";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
};

/**
 * Shows streaming stats (TTFT, total time, tok/s, chunks) as a badge with a
 * hover/focus tooltip. Renders nothing until the stream completes.
 *
 * Place it inside `ActionBarPrimitive.Root` in your `thread.tsx` so it
 * inherits the action bar's autohide behaviour:
 *
 * ```tsx
 * import { MessageTiming } from "@/components/assistant-ui/elements/message-timing.aui";
 *
 * <ActionBarPrimitive.Root >
 *   <ActionBarPrimitive.Copy />
 *   <ActionBarPrimitive.Reload />
 *   <MessageTiming />  // <-- add this
 * </ActionBarPrimitive.Root>
 * ```
 *
 * @param side - Side of the tooltip relative to the badge trigger.
 * @default "right"
 */
export const MessageTiming: FC<{
  className?: string;
  side?: "top" | "right" | "bottom" | "left";
}> = ({ className, side = "right" }) => {
  const timing = useMessageTiming();
  if (timing?.totalStreamTime === undefined) return null;

  return (
    <TooltipProvider>
      <Tooltip>
        <TooltipTrigger asChild>
          <button
            type="button"
            data-slot="message-timing-trigger"
            aria-label={t.timing.title}
            className={cn(
              "text-muted-foreground hover:bg-accent hover:text-accent-foreground flex items-center rounded-md p-1 font-mono text-xs tabular-nums transition-colors",
              className,
            )}
          >
            {formatTimingMs(timing.totalStreamTime)}
          </button>
        </TooltipTrigger>
        <TooltipContent
          side={side}
          sideOffset={8}
          data-slot="message-timing-popover"
          arrow={false}
          className="bg-popover text-popover-foreground border px-3 py-2"
        >
          <div className="grid min-w-35 gap-1.5 text-xs">
            {timing.firstTokenTime !== undefined && (
              <div className="flex items-center justify-between gap-4">
                <span className="text-muted-foreground">{t.timing.firstToken}</span>
                <span className="font-mono tabular-nums">
                  {formatTimingMs(timing.firstTokenTime)}
                </span>
              </div>
            )}
            <div className="flex items-center justify-between gap-4">
              <span className="text-muted-foreground">{t.timing.total}</span>
              <span className="font-mono tabular-nums">
                {formatTimingMs(timing.totalStreamTime)}
              </span>
            </div>
            {timing.tokensPerSecond !== undefined && (
              <div className="flex items-center justify-between gap-4">
                <span className="text-muted-foreground">{t.timing.speed}</span>
                <span className="font-mono tabular-nums">
                  {timing.tokensPerSecond.toFixed(1)} tok/s
                </span>
              </div>
            )}
            <div className="flex items-center justify-between gap-4">
              <span className="text-muted-foreground">{t.timing.items}</span>
              <span className="font-mono tabular-nums">
                {timing.totalChunks}
              </span>
            </div>
          </div>
        </TooltipContent>
      </Tooltip>
    </TooltipProvider>
  );
};
