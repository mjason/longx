import { describe, expect, test } from "vitest";
import { stoppedTurn } from "./stopped";
import type { ThreadView } from "./thread";

const view = (turn: Record<string, unknown> | null, items: Record<string, unknown>[] = []) =>
  ({ turn, items, requests: [], turns: {}, waiting: { items: [], paused: false } }) as unknown as ThreadView;

describe("the stopped last turn", () => {
  test("nothing unless the last turn was stopped", () => {
    expect(stoppedTurn(view(null))).toBeNull();
    expect(stoppedTurn(view({ id: "u1", status: "inProgress" }))).toBeNull();
    expect(stoppedTurn(view({ id: "u1", status: "completed" }))).toBeNull();
  });

  test("the person's own turn that only talked can be discarded; one that ran a command, or another agent's, cannot", () => {
    const opening = { id: "i1", turnId: "u1", type: "userMessage" };
    expect(stoppedTurn(view({ id: "u1", status: "interrupted" }, [opening, { id: "i2", turnId: "u1", type: "agentMessage" }]))).toEqual({
      turnId: "u1",
      byPerson: true,
      discardable: true,
    });
    expect(stoppedTurn(view({ id: "u1", status: "interrupted" }, [opening, { id: "i2", turnId: "u1", type: "commandExecution" }]))?.discardable).toBe(false);
    expect(stoppedTurn(view({ id: "u1", status: "interrupted" }, [{ ...opening, from: "coder" }]))?.discardable).toBe(false);
    expect(stoppedTurn(view({ id: "u1", status: "interrupted", error: { by: "watchdog" } }, [opening]))).toMatchObject({ byPerson: false, discardable: false });
  });
});
