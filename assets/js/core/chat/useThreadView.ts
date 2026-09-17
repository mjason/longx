// React glue: the live view of one kernel thread from its channel.
import { useCallback, useEffect, useReducer, useRef } from "react";
import { getSocket } from "@/core/socket";
import { createBatcher } from "./batch";
import { applyEvent, emptyView, fromSnapshot, type ThreadEvent, type ThreadSnapshot, type ThreadView } from "./thread";
import { joinThreadChannel, type ThreadChannelHandle } from "./threadChannel";

type Action = { type: "snapshot"; snapshot: ThreadSnapshot } | { type: "events"; events: ThreadEvent[] } | { type: "error"; reason: unknown } | { type: "reset"; id: string };

export type ThreadViewState = { view: ThreadView; ready: boolean; error: string | null };

function reduce(state: ThreadViewState, action: Action): ThreadViewState {
  switch (action.type) {
    case "snapshot":
      return { view: fromSnapshot(action.snapshot), ready: true, error: null };
    case "events":
      return { ...state, view: action.events.reduce((view, event) => applyEvent(view, event), state.view) };
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
 * Joins `thread:<kernelThreadId>` (nothing when undefined) and folds its
 * events — a burst of them once per frame (`createBatcher`). `refetch`
 * re-pulls the snapshot in place; a `thread/reverted` does that on its own
 * (the server dropped items we may still show).
 */
// events that are a signal for the person rather than state of the view
const SIGNALS = new Set(["model/rerouted"]);

export function useThreadView(
  kernelThreadId: string | undefined,
  onSignal?: (method: string, params: Record<string, unknown>) => void,
): ThreadViewState & { refetch: () => Promise<void> } {
  const signal = useRef(onSignal);
  signal.current = onSignal;
  const [state, dispatch] = useReducer(reduce, kernelThreadId ?? "", (id) => ({ view: emptyView(id), ready: false, error: null }));
  const handle = useRef<ThreadChannelHandle | null>(null);

  useEffect(() => {
    dispatch({ type: "reset", id: kernelThreadId ?? "" });
    if (!kernelThreadId) return;
    const events = createBatcher<ThreadEvent>((batch) => dispatch({ type: "events", events: batch }));
    const joined = joinThreadChannel(getSocket(), kernelThreadId, {
      onSnapshot: (snapshot) => {
        events.cancel();
        dispatch({ type: "snapshot", snapshot });
      },
      onEvent: (event) => {
        events.push(event);
        if (event.method === "thread/reverted") void joined.snapshot().catch(() => {});
        if (SIGNALS.has(event.method)) signal.current?.(event.method, event.params);
      },
      onError: (reason) => dispatch({ type: "error", reason }),
    });
    handle.current = joined;
    return () => {
      handle.current = null;
      events.cancel();
      joined.leave();
    };
  }, [kernelThreadId]);

  const refetch = useCallback(() => handle.current?.snapshot() ?? Promise.resolve(), []);
  return { ...state, refetch };
}
