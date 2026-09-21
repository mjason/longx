"use client";

import type { ComponentProps, ReactNode } from "react";
import { BotIcon, UserIcon, WrenchIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { mono } from "./surfaces";

export type SpeakerKind = "user" | "agent" | "subagent" | "tool";

export interface SpeakerTurn {
  id: string;
  kind: SpeakerKind;
  name: string;
  detail?: string;
  text: string;
}

const TONE: Record<SpeakerKind, string> = {
  user: "bg-foreground/[0.06] text-foreground/55",
  agent: "bg-blue-500/12 text-blue-600 dark:bg-blue-400/15 dark:text-blue-400",
  subagent: "bg-foreground/[0.06] text-foreground/45",
  tool: "bg-foreground/[0.04] text-foreground/40",
};

/**
 * Longx: one speaker's row on its own — the badge, the name/detail line and,
 * as children, whatever the speaker said (plain text in SpeakerIdentity, a
 * message's rendered parts in the thread). `SpeakerIdentity` stacks these.
 */
export function SpeakerRow({
  kind,
  name,
  detail,
  className,
  children,
  ...props
}: Omit<ComponentProps<"div">, "children"> & {
  kind: SpeakerKind;
  name: ReactNode;
  detail?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div data-slot="speaker-row" className={cn("flex gap-2.5", className)} {...props}>
      <span
        className={cn(
          "flex size-6 shrink-0 items-center justify-center rounded-lg",
          TONE[kind],
          kind === "subagent" && "rounded-full",
        )}
      >
        {kind === "user" ? (
          <UserIcon className="size-3" />
        ) : kind === "tool" ? (
          <WrenchIcon className="size-3" />
        ) : (
          <BotIcon className="size-3" />
        )}
      </span>

      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className="flex items-baseline gap-1.5">
          <span className="text-[13px] font-medium">{name}</span>
          {detail && (
            // Longx: the registry's /30 read as nothing on the dark ground
            <span className={cn(mono, "text-foreground/50")}>
              {detail}
            </span>
          )}
        </span>
        {children}
      </div>
    </div>
  );
}

export function SpeakerIdentity({
  turns,
  className,
  ...props
}: Omit<ComponentProps<"div">, "children" | "turns"> & {
  turns: readonly SpeakerTurn[];
}) {
  return (
    <div
      data-slot="speaker-identity"
      className={cn("flex w-full max-w-sm flex-col gap-3.5", className)}
      {...props}
    >
      {turns.map((turn) => (
        <SpeakerRow key={turn.id} kind={turn.kind} name={turn.name} detail={turn.detail}>
          <span className="text-foreground/65 text-[13.5px] leading-relaxed break-words">
            {turn.text}
          </span>
        </SpeakerRow>
      ))}
    </div>
  );
}
