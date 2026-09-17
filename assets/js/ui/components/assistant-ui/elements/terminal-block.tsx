"use client";

import type { ComponentProps } from "react";
import { CheckIcon, Loader2Icon, XIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { mono, paper } from "./surfaces";
import { take } from "../utils/range";

// Longx: `exitCode`/`exitLabel` replace the demo's fixed "exit 0", `visibleCount`
// defaults to every line, and the block stretches to its container.
export function TerminalBlock({
  command,
  lines,
  visibleCount = lines.length,
  done,
  exitCode = 0,
  exitLabel,
  fullCommand,
  variant = "paper",
  className,
  ...props
}: Omit<
  ComponentProps<"div">,
  "children" | "command" | "lines" | "visibleCount" | "done" | "variant"
> & {
  command: string;
  lines: readonly string[];
  visibleCount?: number;
  done: boolean;
  exitCode?: number | null;
  exitLabel?: string;
  /** what actually ran, when `command` is the readable short form */
  fullCommand?: string;
  variant?: "paper" | "ink";
}) {
  const ink = variant === "ink";
  const failed = exitCode !== 0;

  return (
    <div
      data-slot="terminal-block"
      className={cn(
        ink ? "bg-foreground dark:bg-popover" : paper,
        "w-full overflow-hidden rounded-2xl font-mono text-xs",
        className,
      )}

      {...props}
    >
      <div className="flex items-center justify-between px-4 pt-3 pb-1.5">
        <span
          className={cn(
            "min-w-0 truncate",
            ink
              ? "text-background/90 dark:text-foreground/90"
              : "text-foreground/90",
          )}
          title={fullCommand ?? command}
        >
          {command}
        </span>
        {done ? (
          <div className="flex items-center gap-1">
            {failed ? (
              <XIcon className="size-3 text-red-500" />
            ) : (
              <CheckIcon className="size-3 text-emerald-500" />
            )}
            <span
              className={cn(
                mono,
                failed
                  ? "text-red-600 dark:text-red-400"
                  : ink
                    ? "text-background/40 dark:text-foreground/40"
                    : "text-foreground/40",
              )}
            >
              {exitLabel ?? (exitCode === null ? "" : `exit ${exitCode}`)}
            </span>
          </div>
        ) : (
          <Loader2Icon
            className={cn(
              "size-3 animate-spin motion-reduce:animate-none",
              ink
                ? "text-background/35 dark:text-foreground/35"
                : "text-foreground/35",
            )}
          />
        )}
      </div>
      <div
        className={cn(
          "flex max-h-80 flex-col gap-1 overflow-auto px-4 pt-1 pb-3.5 whitespace-pre",
          ink
            ? "text-background/55 dark:text-foreground/50"
            : "text-foreground/50",
        )}
      >
        {take(lines, visibleCount).map((line, i) => {
          const isLast = i === lines.length - 1;
          return (
            <div
              key={`${i}-${line}`}
              className={cn(
                "fade-in animate-in fill-mode-both duration-300",
                isLast &&
                  (ink
                    ? "text-background/90 dark:text-foreground/90"
                    : "text-foreground/90"),
              )}
            >
              {linkify(line)}
            </div>
          );
        })}
        {!done && (
          <span
            aria-hidden
            className="inline-block h-3 w-1.5 animate-pulse bg-blue-500/70 motion-reduce:animate-none dark:bg-blue-400/70"
          />
        )}
      </div>
    </div>
  );
}

// a URL in the output is a link (a login page a tool printed, a report's source)
const URL_RE = /https?:\/\/[^\s<>"'`）)]+/g;
function linkify(line: string) {
  const parts: React.ReactNode[] = [];
  let last = 0;
  for (const m of line.matchAll(URL_RE)) {
    const at = m.index ?? 0;
    if (at > last) parts.push(line.slice(last, at));
    parts.push(
      <a key={at} href={m[0]} target="_blank" rel="noopener noreferrer" className="underline decoration-dotted underline-offset-2 hover:opacity-80">
        {m[0]}
      </a>,
    );
    last = at + m[0].length;
  }
  if (parts.length === 0) return line;
  if (last < line.length) parts.push(line.slice(last));
  return parts;
}
