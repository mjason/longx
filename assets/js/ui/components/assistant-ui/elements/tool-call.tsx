"use client";

import type { ReactNode } from "react";
import { CheckIcon, ChevronRightIcon, XIcon } from "lucide-react";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/ui/components/ui/collapsible";
import { cn } from "@/lib/utils";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/ui/components/ui/tooltip";
import {
  collapsePanel,
  field,
  mono,
  ShimmerLabel,
  SwapLabel,
} from "./surfaces";

// Longx: `children` replaces the request/result panel with a real body
// (terminal block, diff, search results); `failed` swaps the check for a
// cross. Everything else is the registry's.
export interface ToolCallProps {
  label: string;
  activeLabel: string;
  query: string;
  // Longx: what the chip shows on hover — the whole query (it is truncated in
  // the row) and whatever the caller adds (a command's directory)
  queryDetail?: ReactNode;
  request?: string;
  result?: string;
  // Longx: how long the call took (or has been running), at the end of the
  // row before the mark — the registry's Tool timeline element's convention
  duration?: ReactNode;
  /** A compact result, kept visible even when the body is collapsed. */
  statusLabel?: string;
  running: boolean;
  failed?: boolean;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  className?: string;
  children?: ReactNode;
  /** Long file changes retain a visible disclosure and an end-of-content exit. */
  collapseLabel?: string;
}

export function ToolCall({
  label,
  activeLabel,
  query,
  queryDetail,
  request = "",
  result = "",
  duration,
  statusLabel,
  running,
  failed = false,
  open,
  onOpenChange,
  className,
  children,
  collapseLabel,
}: ToolCallProps) {
  return (
    <Collapsible
      data-slot="tool-call"
      data-file-change-open={collapseLabel && open ? "" : undefined}
      open={open}
      onOpenChange={onOpenChange}
      className={cn("w-full max-w-sm", className)}
    >
      <CollapsibleTrigger className={cn(
        "group/trigger text-foreground/55 hover:text-foreground/90 flex w-full max-w-full items-center gap-2 rounded-md py-1 text-[13.5px] transition-colors outline-none",
        collapseLabel && open && "sticky top-0 z-20 bg-background py-2 shadow-sm",
      )}>
        <ChevronRightIcon className="size-3.5 shrink-0 opacity-60 transition-transform duration-200 ease-[cubic-bezier(0.32,0.72,0,1)] group-data-open/trigger:rotate-90 group-data-panel-open/trigger:rotate-90 motion-reduce:transition-none" />
        <SwapLabel active={running ? 0 : 1} className="text-start">
          <ShimmerLabel
            active={running}
            className="relative inline-block leading-none"
          >
            {activeLabel}
          </ShimmerLabel>
          <>{label}</>
        </SwapLabel>
        <TooltipProvider delayDuration={300}>
          <Tooltip>
            <TooltipTrigger asChild>
              <span
                className={cn(
                  mono,
                  "bg-foreground/[0.06] text-foreground/70 min-w-0 truncate rounded-md px-1.5 py-0.5",
                )}
                data-testid="tool-call-query"
              >
                {query}
              </span>
            </TooltipTrigger>
            <TooltipContent
              side="bottom"
              align="start"
              sideOffset={6}
              arrow={false}
              className="bg-popover text-popover-foreground max-w-[min(40rem,90vw)] border px-3 py-2 text-start"
            >
              {queryDetail ?? (
                <pre className={cn(mono, "text-foreground/80 max-h-64 overflow-y-auto font-mono text-xs break-all whitespace-pre-wrap")}>{query}</pre>
              )}
            </TooltipContent>
          </Tooltip>
        </TooltipProvider>
        {statusLabel ? (
          <span className={cn(mono, "shrink-0 rounded px-1.5 py-0.5",
            failed ? "bg-destructive/10 text-destructive" : "bg-muted text-muted-foreground")}>
            {statusLabel}
          </span>
        ) : null}
        {duration ? (
          <span className={cn(mono, "text-foreground/35 ms-auto shrink-0 tabular-nums")} data-testid="tool-call-duration">
            {duration}
          </span>
        ) : null}
        <span className={cn("flex w-4 shrink-0 items-center justify-end", !duration && "ms-auto")}>
          {!running && !failed && (
            <CheckIcon className="fade-in zoom-in-90 animate-in size-3.5 text-emerald-500 duration-200" />
          )}
          {!running && failed && (
            <XIcon className="fade-in zoom-in-90 animate-in size-3.5 text-red-500 duration-200" />
          )}
        </span>
        {collapseLabel && open ? (
          <span className="text-muted-foreground shrink-0 text-xs">{collapseLabel}</span>
        ) : null}
      </CollapsibleTrigger>
      {/* File changes close immediately so their scroll anchor is restored against
          final geometry, not an intermediate height animation. Other tools keep it. */}
      <CollapsibleContent className={cn(!collapseLabel && collapsePanel, "outline-none")}>
        {children ? (
          <div className="mt-2">{children}</div>
        ) : (
        <div className={cn(field, "mt-2 overflow-hidden rounded-2xl text-xs")}>
          <div className="px-3.5 pt-2.5 pb-2">
            <p className={cn(mono, "text-foreground/35 mb-1")}>Request</p>
            <p className="text-foreground/55 font-mono">{request}</p>
          </div>
          <div className="bg-foreground/[0.06] mx-3.5 h-px" />
          <div className="px-3.5 pt-2 pb-2.5">
            <p className={cn(mono, "text-foreground/35 mb-1")}>Result</p>
            <p className="text-foreground/90">{result}</p>
          </div>
        </div>
        )}
        {collapseLabel ? (
          <div className="mt-2 flex justify-end border-t border-border/50 pt-2">
            <CollapsibleTrigger className="text-muted-foreground hover:text-foreground inline-flex min-h-9 items-center gap-1 rounded-md px-3 text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
              <ChevronRightIcon className="size-3.5 -rotate-90" />
              {collapseLabel}
            </CollapsibleTrigger>
          </div>
        ) : null}
      </CollapsibleContent>
    </Collapsible>
  );
}
