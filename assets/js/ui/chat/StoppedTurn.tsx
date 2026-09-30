import { useTranslation } from "react-i18next";
// A turn stopped once the model had answered stays where it is and says so,
// with 继续 and — for a turn the person started that ran nothing — 丢弃
// (assistant-ui's stopped-run element). A turn stopped before the model
// answered never gets here: the adapter took it back into the composer.
import { useAuiState } from "@assistant-ui/react";
import { startedByPerson, turnHadEffects } from "@/core/chat/adapter";
import { StoppedRun } from "@/ui/components/assistant-ui/elements/stopped-run";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

export function StoppedTurnView({ byPerson, onContinue, onDiscard }: { byPerson: boolean; onContinue: () => void; onDiscard?: (() => void) | undefined }) {
    useTranslation();
  return (
    <StoppedRun
      data-testid="stopped-turn"
      className="mt-2 max-w-none"
      reason={byPerson ? t.stoppedByPerson : t.stoppedByWatchdog}
      continueLabel={t.stoppedContinue}
      discardLabel={t.stoppedDiscard}
      onContinue={onContinue}
      {...(onDiscard ? { onDiscard } : {})}
    />
  );
}

// the message ids of a turn are `turn:<id>` and `turn:<id>:<n>` (messages.ts)
const turnOfMessage = (id: string): string | undefined => id.match(/^turn:([^:]+)/)?.[1];

/** Under the thread's last message when its turn was stopped (the Thread's `StoppedNotice` slot). */
export function StoppedNotice() {
    useTranslation();
  const cancelled = useAuiState((s) => s.message.role === "assistant" && s.message.status?.type === "incomplete" && s.message.status.reason === "cancelled");
  const isLast = useAuiState((s) => s.message.isLast);
  const messageId = useAuiState((s) => s.message.id);
  const { view, sendText, discardTurn } = useChat();
  if (!cancelled || !isLast) return null;
  const turnId = turnOfMessage(messageId);
  const error = view.turn?.["error"] as { by?: string } | undefined;
  const byPerson = error?.by !== "watchdog";
  const discardable = byPerson && turnId !== undefined && startedByPerson(view, turnId) && !turnHadEffects(view, turnId);
  return (
    <StoppedTurnView
      byPerson={byPerson}
      onContinue={() => void sendText(t.continueText)}
      onDiscard={discardable ? () => void discardTurn(turnId) : undefined}
    />
  );
}
