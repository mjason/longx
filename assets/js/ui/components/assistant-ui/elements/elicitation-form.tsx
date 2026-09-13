"use client";

import type { ComponentProps } from "react";
import { CheckIcon, MessageCircleQuestionIcon, XIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { field, inkButton, mono, paper } from "./surfaces";

// Longx: the registry's form is a display mock; this one is interactive
// (`onChange`) and worded through props, so codex's requestUserInput
// questions can be answered in it.
export type ElicitationState = "request" | "accepted" | "declined";

export interface ElicitationField {
  name: string;
  label: string;
  value: string;
  kind: "text" | "choice" | "toggle";
  options?: readonly string[];
  /** with `choice`: a free-text answer is accepted too */
  freeform?: boolean;
  secret?: boolean;
  required?: boolean;
  /** one line under the label */
  hint?: string;
}

export type ElicitationLabels = {
  needsInput: string;
  send: string;
  decline: string;
  sent: string;
  declined: string;
  other: string;
};

const DEFAULT_LABELS: ElicitationLabels = {
  needsInput: "needs input",
  send: "Send",
  decline: "Decline",
  sent: "Sent",
  declined: "Declined",
  other: "Other…",
};

export function ElicitationForm({
  server,
  message,
  fields,
  state,
  labels = DEFAULT_LABELS,
  disabled = false,
  onChange,
  onAccept,
  onDecline,
  className,
  ...props
}: Omit<ComponentProps<"div">, "children" | "server" | "message" | "fields" | "state" | "onChange"> & {
  server: string;
  message: string;
  fields: readonly ElicitationField[];
  state: ElicitationState;
  labels?: ElicitationLabels;
  disabled?: boolean;
  onChange?: (name: string, value: string) => void;
  onAccept?: () => void;
  onDecline?: () => void;
}) {
  const complete = fields.every((f) => !f.required || f.value.trim() !== "");
  return (
    <div data-slot="elicitation-form" className={cn(paper, "flex w-full max-w-xl flex-col gap-3.5 rounded-[20px] p-4", className)} {...props}>
      <div className="flex items-center gap-2.5">
        <span className="bg-foreground/[0.05] text-foreground/45 flex size-7 shrink-0 items-center justify-center rounded-lg">
          <MessageCircleQuestionIcon className="size-3.5" />
        </span>
        <span className="min-w-0 flex-1 truncate text-[13.5px] font-medium">{server}</span>
        <span className={cn(mono, "text-foreground/30 shrink-0")}>{labels.needsInput}</span>
      </div>
      {message ? <p className="text-foreground/55 text-xs leading-relaxed">{message}</p> : null}
      <div className="flex flex-col gap-3">
        {fields.map((item) => {
          const chosen = item.options?.includes(item.value) ?? false;
          return (
            <div key={item.name} className="flex flex-col gap-1.5">
              <span className="text-foreground/80 text-sm">
                {item.label}
                {item.required && <span className="text-foreground/25"> *</span>}
              </span>
              {item.hint ? <span className={cn(mono, "text-foreground/35")}>{item.hint}</span> : null}
              {item.kind === "choice" ? (
                <div className="flex flex-wrap gap-1.5">
                  {item.options?.map((option) => (
                    <button
                      key={option}
                      type="button"
                      disabled={disabled || state !== "request"}
                      aria-pressed={option === item.value}
                      onClick={() => onChange?.(item.name, option)}
                      className={cn(
                        "rounded-full px-2.5 py-1 text-xs transition-colors",
                        option === item.value ? "bg-foreground text-background" : cn(field, "text-foreground/55 hover:text-foreground/90"),
                      )}
                    >
                      {option}
                    </button>
                  ))}
                </div>
              ) : null}
              {item.kind === "text" || (item.kind === "choice" && item.freeform) ? (
                <input
                  type={item.secret ? "password" : "text"}
                  aria-label={item.kind === "choice" ? `${item.label} ${labels.other}` : item.label}
                  placeholder={item.kind === "choice" ? labels.other : undefined}
                  value={item.kind === "choice" && chosen ? "" : item.value}
                  disabled={disabled || state !== "request"}
                  onChange={(e) => onChange?.(item.name, e.target.value)}
                  className={cn(field, "text-foreground/80 w-full rounded-lg px-2.5 py-1.5 text-xs outline-none focus:ring-1 focus:ring-ring")}
                />
              ) : null}
              {item.kind === "toggle" ? (
                <button
                  type="button"
                  role="switch"
                  aria-checked={item.value === "true"}
                  aria-label={item.label}
                  disabled={disabled || state !== "request"}
                  onClick={() => onChange?.(item.name, item.value === "true" ? "false" : "true")}
                  className="flex items-center gap-2"
                >
                  <span aria-hidden className={cn("flex h-4 w-7 items-center rounded-full p-0.5 transition-colors duration-200", item.value === "true" ? "bg-foreground/80" : "bg-foreground/15")}>
                    <span className={cn("bg-background size-3 rounded-full transition-transform duration-200 motion-reduce:transition-none", item.value === "true" && "translate-x-3")} />
                  </span>
                </button>
              ) : null}
            </div>
          );
        })}
      </div>
      <div className="flex min-h-8 items-center justify-end gap-2">
        {state === "request" ? (
          <>
            {onDecline ? (
              <button
                type="button"
                onClick={onDecline}
                disabled={disabled}
                className="text-foreground/55 hover:bg-foreground/[0.06] hover:text-foreground/90 h-8 rounded-full px-3.5 text-xs font-medium transition-[background-color,color,scale] duration-150 active:scale-[0.96]"
              >
                {labels.decline}
              </button>
            ) : null}
            <button
              type="button"
              onClick={onAccept}
              disabled={disabled || !complete}
              className={cn(inkButton, "flex h-8 items-center rounded-full px-3.5 text-xs font-medium disabled:opacity-50")}
            >
              {labels.send}
            </button>
          </>
        ) : (
          <span key={state} className="fade-in animate-in text-foreground/55 flex items-center gap-2 text-xs duration-300">
            {state === "accepted" ? (
              <>
                <CheckIcon className="size-3.5 text-emerald-500" />
                {labels.sent}
              </>
            ) : (
              <>
                <XIcon className="text-foreground/45 size-3.5" />
                {labels.declined}
              </>
            )}
          </span>
        )}
      </div>
    </div>
  );
}
