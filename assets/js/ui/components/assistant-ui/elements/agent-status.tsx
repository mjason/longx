"use client";

import type { ComponentProps, ReactNode } from "react";
import { CheckIcon, PauseIcon, RotateCcwIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { mono, paper } from "./surfaces";

export type AgentState = "working" | "waiting" | "done";

export interface StatusStep {
  state: AgentState;
  label: string;
}

// Longx: the trailing pause / restart glyph is the demo's; `action` replaces
// it (null = none) since our pill does not act.
export function AgentStatus({
  state,
  label,
  elapsed,
  action,
  className,
  ...props
}: Omit<ComponentProps<"div">, "children" | "state" | "label" | "elapsed"> & {
  state: AgentState;
  label: string;
  elapsed?: string;
  action?: ReactNode;
}) {
  return (
    <div
      data-slot="agent-status"
      className={cn(
        paper,
        "flex items-center gap-2.5 rounded-full py-1.5 ps-3.5 pe-1.5",
        className,
      )}

      {...props}
    >
      {state === "done" ? (
        <CheckIcon aria-hidden className="size-3 shrink-0 text-emerald-500" />
      ) : (
        <span
          aria-hidden
          className={cn(
            "size-1.5 shrink-0 rounded-full motion-reduce:animate-none",
            state === "working"
              ? "animate-pulse bg-blue-500 dark:bg-blue-400"
              : "border-foreground/35 border",
          )}
        />
      )}
      <span className="sr-only">{state}</span>
      <span
        key={label}
        className="fade-in blur-in-[2px] animate-in max-w-44 truncate text-xs duration-300 motion-reduce:animate-none"
      >
        {label}
      </span>
      {elapsed !== undefined && state !== "done" && (
        <span className={cn(mono, "text-foreground/30 tabular-nums")}>
          {elapsed}
        </span>
      )}
      {action === undefined ? (
        <span
          aria-hidden
          className="text-foreground/45 flex size-6 items-center justify-center rounded-full"
        >
          {state === "done" ? (
            <RotateCcwIcon className="size-3" />
          ) : (
            <PauseIcon className="size-3" />
          )}
        </span>
      ) : (
        action
      )}
    </div>
  );
}
