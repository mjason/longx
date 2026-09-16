"use client";

import type { ComponentProps, ReactNode } from "react";
import { CheckIcon, Loader2Icon, TerminalIcon, XIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { field, inkButton, paper } from "./surfaces";

export type ApprovalState = "request" | "running" | "done" | "denied";

// Longx: labels come in as props (zh-CN UI), `command` may be any node
// (a file list), and the icon can be swapped per approval kind.
export type ApprovalLabels = {
  allowOnce: string;
  alwaysAllow: string;
  deny: string;
  running?: string;
  denied?: string;
  done?: string;
  /** Longx: the button next to a denial that lets the person allow the action anyway */
  override?: string;
};

const DEFAULT_LABELS: ApprovalLabels = {
  allowOnce: "Allow once",
  alwaysAllow: "Always allow",
  deny: "Deny",
  running: "Approved, running",
  denied: "Denied",
  done: "Finished with exit 0",
};

export function ApprovalCard({
  state,
  command,
  title,
  subtitle,
  icon,
  labels = DEFAULT_LABELS,
  disabled = false,
  onAllowOnce,
  onAlwaysAllow,
  onDeny,
  onOverride,
  className,
  ...props
}: Omit<
  ComponentProps<"div">,
  | "children"
  | "state"
  | "command"
  | "title"
  | "subtitle"
  | "onAllowOnce"
  | "onAlwaysAllow"
  | "onDeny"
  | "onOverride"
> & {
  state: ApprovalState;
  command: ReactNode;
  title: string;
  subtitle: string;
  icon?: ReactNode;
  labels?: ApprovalLabels;
  disabled?: boolean;
  onAllowOnce?: () => void;
  onAlwaysAllow?: () => void;
  onDeny?: () => void;
  /** shown in the `denied` state: allow the action after all (an automatic review's denial) */
  onOverride?: () => void;
}) {
  return (
    <div
      data-slot="approval-card"
      className={cn(
        paper,
        "flex w-full max-w-xl flex-col gap-3.5 rounded-[20px] p-4",
        className,
      )}

      {...props}
    >
      <div className="flex items-center gap-3">
        <span className="bg-foreground/[0.05] text-foreground/45 flex size-9 shrink-0 items-center justify-center rounded-xl">
          {icon ?? <TerminalIcon className="size-4" />}
        </span>
        <div className="flex flex-col">
          <p className="text-[13.5px] font-medium">{title}</p>
          <p className="text-foreground/45 text-xs">{subtitle}</p>
        </div>
      </div>

      <div
        className={cn(
          field,
          "text-foreground/70 overflow-x-auto rounded-xl px-3.5 py-2.5 font-mono text-xs",
        )}
      >
        {command}
      </div>

      <div className="flex min-h-8 flex-wrap items-center justify-end gap-2">
        {state === "request" ? (
          <>
            <button
              type="button"
              onClick={onDeny}
              disabled={disabled}
              className="text-foreground/55 hover:bg-foreground/[0.06] hover:text-foreground/90 h-8 rounded-full px-3.5 text-xs font-medium transition-[background-color,color,scale] duration-150 active:scale-[0.96]"
            >
              {labels.deny}
            </button>
            {onAlwaysAllow ? (
            <button
              type="button"
              onClick={onAlwaysAllow}
              disabled={disabled}
              className="text-foreground/55 hover:bg-foreground/[0.06] hover:text-foreground/90 h-8 rounded-full px-3.5 text-xs font-medium transition-[background-color,color,scale] duration-150 active:scale-[0.96]"
            >
              {labels.alwaysAllow}
            </button>
            ) : null}
            <button
              type="button"
              onClick={onAllowOnce}
              disabled={disabled}
              className={cn(
                inkButton,
                "flex h-8 items-center rounded-full px-3.5 text-xs font-medium",
              )}
            >
              {labels.allowOnce}
            </button>
          </>
        ) : (
          <div
            key={state}
            className="fade-in animate-in text-foreground/55 flex items-center gap-2 text-xs duration-300"
          >
            {state === "running" ? (
              <>
                <Loader2Icon className="text-foreground/45 size-3.5 animate-spin" />
                {labels.running ?? DEFAULT_LABELS.running}
              </>
            ) : state === "denied" ? (
              <>
                <XIcon className="text-foreground/45 size-3.5" />
                {labels.denied ?? DEFAULT_LABELS.denied}
                {onOverride ? (
                  <button
                    type="button"
                    onClick={onOverride}
                    disabled={disabled}
                    className={cn(inkButton, "ml-2 flex h-8 items-center rounded-full px-3.5 text-xs font-medium")}
                  >
                    {labels.override ?? "Allow anyway"}
                  </button>
                ) : null}
              </>
            ) : (
              <>
                <CheckIcon className="size-3.5 text-emerald-500" />
                {labels.done ?? DEFAULT_LABELS.done}
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
