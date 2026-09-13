// React glue: the live view of one codex thread from its channel.
import { useEffect, useReducer } from "react";
import { getSocket } from "@/core/socket";
import { applyEvent, emptyView, fromSnapshot, type ThreadEvent, type ThreadSnapshot, type ThreadView } from "./thread";
import { joinThreadChannel } from "./threadChannel";

type Action = { type: "snapshot"; snapshot: ThreadSnapshot } | { type: "event"; event: ThreadEvent } | { type: "error"; reason: unknown };

export type ThreadViewState = { view: ThreadView; ready: boolean; error: string | null };

function reduce(state: ThreadViewState, action: Action): ThreadViewState {
  switch (action.type) {
    case "snapshot":
      return { view: fromSnapshot(action.snapshot), ready: true, error: null };
    case "event":
      return { ...state, view: applyEvent(state.view, action.event) };
    case "error":
      return { ...state, error: describe(action.reason) };
  }
}

function describe(reason: unknown): string {
  if (reason && typeof reason === "object" && "reason" in reason) return String((reason as { reason: unknown }).reason);
  return String(reason);
}

export function useThreadView(codexThreadId: string | undefined): ThreadViewState {
  const [state, dispatch] = useReducer(reduce, codexThreadId ?? "", (id) => ({ view: emptyView(id), ready: false, error: null }));

  useEffect(() => {
    if (!codexThreadId) return;
    return joinThreadChannel(getSocket(), codexThreadId, {
      onSnapshot: (snapshot) => dispatch({ type: "snapshot", snapshot }),
      onEvent: (event) => dispatch({ type: "event", event }),
      onError: (reason) => dispatch({ type: "error", reason }),
    });
  }, [codexThreadId]);

  return state;
}
