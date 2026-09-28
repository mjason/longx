// The thread's last turn when the person (or the watchdog) stopped it: what
// the stopped-run card under it offers — 继续 always, 丢弃 only for the
// person's own turn that ran nothing (the same rule as StoppedNotice) — for
// the space menu's SPC a r / SPC a d.
import { startedByPerson, turnHadEffects } from "./adapter";
import type { ThreadView } from "./thread";

export type StoppedTurn = { turnId: string; byPerson: boolean; discardable: boolean };

export function stoppedTurn(view: ThreadView): StoppedTurn | null {
  const turn = view.turn;
  if (!turn || turn["status"] !== "interrupted" || typeof turn["id"] !== "string") return null;
  const turnId = turn["id"];
  const error = turn["error"] as { by?: string } | undefined;
  const byPerson = error?.by !== "watchdog";
  return { turnId, byPerson, discardable: byPerson && startedByPerson(view, turnId) && !turnHadEffects(view, turnId) };
}
