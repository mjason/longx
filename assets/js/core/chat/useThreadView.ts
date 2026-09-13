// React glue: the live view of one codex thread from its channel.
import { useCallback, useEffect, useReducer, useRef } from "react";
import { getSocket } from "@/core/socket";
import { applyEvent, emptyView, fromSnapshot, type ThreadEvent, type ThreadSnapshot, type ThreadView } from "./thread";
import { joinThreadChannel, type ThreadChannelHandle } from "./threadChannel";

type Action = { type: "snapshot"; snapshot: ThreadSnapshot } | { type: "event"; event: ThreadEvent } | { type: "error"; reason: unknown } | { type: "reset"; id: string };

export type ThreadViewState = { view: ThreadView; ready: boolean; error: string | null };

function reduce(state: ThreadViewState, action: Action): ThreadViewState {
  switch (action.type) {
    case "snapshot":
      return { view: fromSnapshot(action.snapshot), ready: true, error: null };
    case "event":
      return { ...state, view: applyEvent(state.view, action.event) };
    case "error":
      return { ...state, error: describe(action.reason) };
    case "reset":
      return { view: emptyView(action.id), ready: false, error: null };
  }
}

function describe(reason: unknown): string {
  if (reason && typeof reason === "object" && "reason" in reason) return String((reason as { reason: unknown }).reason);
  return String(reason);
}

/**
 * Joins `thread:<codexThreadId>` (nothing when undefined) and folds its
 * events. `refetch` re-pulls the snapshot in place; a `thread/reverted`
 * does that on its own (the server dropped items we may still show).
 */
export function useThreadView(codexThreadId: string | undefined): ThreadViewState & { refetch: () => Promise<void> } {
  const [state, dispatch] = useReducer(reduce, codexThreadId ?? "", (id) => ({ view: emptyView(id), ready: false, error: null }));
  const handle = useRef<ThreadChannelHandle | null>(null);

  useEffect(() => {
    dispatch({ type: "reset", id: codexThreadId ?? "" });
    if (!codexThreadId) return;
    const joined = joinThreadChannel(getSocket(), codexThreadId, {
      onSnapshot: (snapshot) => dispatch({ type: "snapshot", snapshot }),
      onEvent: (event) => {
        dispatch({ type: "event", event });
        if (event.method === "thread/reverted") void joined.snapshot().catch(() => {});
      },
      onError: (reason) => dispatch({ type: "error", reason }),
    });
    handle.current = joined;
    return () => {
      handle.current = null;
      joined.leave();
    };
  }, [codexThreadId]);

  const refetch = useCallback(() => handle.current?.snapshot() ?? Promise.resolve(), []);
  return { ...state, refetch };
}
