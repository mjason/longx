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
  running: boolean;
  failed?: boolean;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  className?: string;
  children?: ReactNode;
}

export function ToolCall({
  label,
  activeLabel,
  query,
  queryDetail,
  request = "",
  result = "",
  running,
  failed = false,
  open,
  onOpenChange,
  className,
  children,
}: ToolCallProps) {
  return (
    <Collapsible
      data-slot="tool-call"
      open={open}
      onOpenChange={onOpenChange}
      className={cn("w-full max-w-sm", className)}
    >
      <CollapsibleTrigger className="group/trigger text-foreground/55 hover:text-foreground/90 flex w-full max-w-full items-center gap-2 rounded-md py-1 text-[13.5px] transition-colors outline-none">
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
        <span className="ms-auto flex w-4 shrink-0 items-center justify-end">
          {!running && !failed && (
            <CheckIcon className="fade-in zoom-in-90 animate-in size-3.5 text-emerald-500 duration-200" />
          )}
          {!running && failed && (
            <XIcon className="fade-in zoom-in-90 animate-in size-3.5 text-red-500 duration-200" />
          )}
        </span>
      </CollapsibleTrigger>
      <CollapsibleContent className={cn(collapsePanel, "outline-none")}>
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
      </CollapsibleContent>
    </Collapsible>
  );
}
