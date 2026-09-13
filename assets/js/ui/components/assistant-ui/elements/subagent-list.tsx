"use client";

import type { ComponentProps } from "react";
import { CheckIcon, Loader2Icon } from "lucide-react";
import { cn } from "@/lib/utils";
import { mono, paper } from "./surfaces";
import { pct } from "../utils/range";

// Longx: agents are what codex reports, not a demo — `model` and progress
// are optional (a running agent shows the shimmer bar), `done` marks each
// agent itself (`completedCount` still works for ordered lists) and the
// summary card is opt-in.
export interface SubagentItem {
  name: string;
  model?: string;
  done?: boolean;
}

export function SubagentList({
  agents,
  completedCount,
  progress,
  showSummary,
  summaryAgent,
  className,
  ...props
}: Omit<
  ComponentProps<"div">,
  | "children"
  | "agents"
  | "completedCount"
  | "progress"
  | "showSummary"
  | "summaryAgent"
> & {
  agents: readonly SubagentItem[];
  completedCount?: number;
  progress?: readonly number[];
  showSummary?: boolean;
  summaryAgent?: SubagentItem;
}) {
  return (
    <div
      data-slot="subagent-list"
      className={cn(
        "flex w-full max-w-xs flex-col gap-2",
        className,
      )}

      {...props}
    >
      {agents.map((agent, index) => {
        const done = agent.done ?? (completedCount !== undefined && index < completedCount);
        const width = progress?.[index] ?? (done ? 100 : undefined);
        const percentage = width === undefined ? undefined : pct(width, 100);

        return (
          <div
            key={agent.name}
            className={cn(
              paper,
              "flex flex-col gap-2 rounded-2xl px-3.5 py-2.5",
            )}
          >
            <div className="flex items-center gap-2">
              {done ? (
                <CheckIcon className="fade-in zoom-in-90 animate-in size-3.5 shrink-0 text-emerald-500 duration-200" />
              ) : (
                <Loader2Icon className="text-foreground/35 size-3.5 shrink-0 animate-spin motion-reduce:animate-none" />
              )}
              <span className="flex-1 truncate text-[13.5px]">
                {agent.name}
              </span>
              {agent.model !== undefined && (
                <span className={cn(mono, "text-foreground/35")}>
                  {agent.model}
                </span>
              )}
            </div>
            <span
              role="progressbar"
              aria-label={`${agent.name} progress`}
              aria-valuemin={0}
              aria-valuemax={100}
              {...(percentage !== undefined ? { "aria-valuenow": percentage } : {})}
              className="bg-foreground/[0.06] h-[3px] w-full overflow-hidden rounded-full"
            >
              {percentage === undefined ? (
                <span className="shimmer shimmer-bg block h-full w-full rounded-full motion-reduce:animate-none" />
              ) : (
                <span
                  className={cn(
                    "block h-full rounded-full transition-[width] duration-700",
                    done ? "bg-emerald-500/70" : "bg-foreground/60",
                  )}
                  style={{ width: `${percentage}%` }}
                />
              )}
            </span>
          </div>
        );
      })}
      {showSummary && summaryAgent && (
        <div
          className={cn(
            paper,
            "fade-in slide-in-from-bottom-2 animate-in flex flex-col gap-2 rounded-2xl px-3.5 py-2.5 duration-300",
          )}
        >
          <div className="flex items-center gap-2">
            <Loader2Icon className="text-foreground/35 size-3.5 shrink-0 animate-spin motion-reduce:animate-none" />
            <span className="flex-1 truncate text-[13.5px]">
              {summaryAgent.name}
            </span>
            {summaryAgent.model !== undefined && (
              <span className={cn(mono, "text-foreground/35")}>
                {summaryAgent.model}
              </span>
            )}
          </div>
          <span
            role="progressbar"
            aria-label={`${summaryAgent.name} progress`}
            aria-valuemin={0}
            aria-valuemax={100}
            className="bg-foreground/[0.06] h-[3px] w-full overflow-hidden rounded-full"
          >
            <span className="shimmer shimmer-bg block h-full w-full rounded-full motion-reduce:animate-none" />
          </span>
        </div>
      )}
    </div>
  );
}
