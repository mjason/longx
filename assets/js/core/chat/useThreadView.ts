// React glue: the live view of one kernel thread from its channel.
import { useCallback, useEffect, useReducer, useRef } from "react";
import { getSocket, joinBreaker } from "@/core/socket";
import { t } from "@/ui/strings";
import { createBatcher } from "./batch";
import { applyEvent, emptyView, fromSnapshot, HISTORY_PAGE, prependEarlier, type EarlierPage, type ThreadEvent, type ThreadSnapshot, type ThreadView } from "./thread";
import { joinThreadChannel, type ThreadChannelHandle } from "./threadChannel";

type Action =
  | { type: "snapshot"; snapshot: ThreadSnapshot }
  | { type: "events"; events: ThreadEvent[] }
  | { type: "earlier"; page: EarlierPage }
  | { type: "error"; reason: unknown }
  | { type: "reset"; id: string };

export type ThreadViewState = { view: ThreadView; ready: boolean; error: string | null };

function reduce(state: ThreadViewState, action: Action): ThreadViewState {
  switch (action.type) {
    case "snapshot":
      return { view: fromSnapshot(action.snapshot), ready: true, error: null };
    case "events":
      return { ...state, view: action.events.reduce((view, event) => applyEvent(view, event), state.view) };
    case "earlier":
      return { ...state, view: prependEarlier(state.view, action.page) };
    case "error":
      return { ...state, error: describe(action.reason) };
    case "reset":
      return { view: emptyView(action.id), ready: false, error: null };
  }
}

function describe(reason: unknown): string {
  if (reason && typeof reason === "object" && "reason" in reason) {
    const r = (reason as { reason: unknown }).reason;
    // the join breaker gave this thread up: its join kept taking the socket down
    if (r === "unstable") return t.threadUnstable;
    return String(r);
  }
  return String(reason);
}

/**
 * Joins `thread:<kernelThreadId>` (nothing when undefined) and folds its
 * events — a burst of them once per frame (`createBatcher`). `refetch`
 * re-pulls the snapshot in place; a `thread/reverted` does that on its own
 * (the server dropped items we may still show). The view is a window on the
 * tail (`HISTORY_PAGE` items, the last turn whole); `loadEarlier` fetches a
 * page from above it, and a rejoin asks for as much as the view had.
 */
// events that are a signal for the person rather than state of the view
const SIGNALS = new Set(["model/rerouted"]);

// a surface the agent opened for the person (show_file / show_diff /
// show_html): only a *live* item opens it — a snapshot never signals, so a
// replay after a reload draws the row and leaves the workbench alone
export const SURFACE_TOOLS = new Set(["show_file", "show_diff", "show_html"]);

export function isSurfaceEvent(event: ThreadEvent): boolean {
  if (event.method !== "item/completed") return false;
  const item = event.params["item"] as Record<string, unknown> | undefined;
  return item?.["type"] === "dynamicToolCall" && item["namespace"] === "longx" && SURFACE_TOOLS.has(String(item["tool"])) && item["success"] === true;
}

export type LoadEarlier = (count: number | "all") => Promise<void>;

export function useThreadView(
  kernelThreadId: string | undefined,
  onSignal?: (method: string, params: Record<string, unknown>) => void,
): ThreadViewState & { refetch: () => Promise<void>; loadEarlier: LoadEarlier } {
  const signal = useRef(onSignal);
  signal.current = onSignal;
  const [state, dispatch] = useReducer(reduce, kernelThreadId ?? "", (id) => ({ view: emptyView(id), ready: false, error: null }));
  const latest = useRef(state);
  latest.current = state;
  const handle = useRef<ThreadChannelHandle | null>(null);
  const current = useRef(kernelThreadId);
  current.current = kernelThreadId;

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
        if (SIGNALS.has(event.method) || isSurfaceEvent(event)) signal.current?.(event.method, event.params);
      },
      onError: (reason) => dispatch({ type: "error", reason }),
    }, {
      breaker: joinBreaker(),
      // a reconnect keeps what the reader had scrolled up to
      limit: () => Math.max(HISTORY_PAGE, latest.current.view.items.length),
    });
    handle.current = joined;
    return () => {
      handle.current = null;
      events.cancel();
      joined.leave();
    };
  }, [kernelThreadId]);

  const refetch = useCallback(() => handle.current?.snapshot() ?? Promise.resolve(), []);
  // a page from above the view's first item; one the server no longer knows
  // (a retract took its turn) means the view is stale: snapshot again
  const loadEarlier = useCallback<LoadEarlier>(async (count) => {
    const joined = handle.current;
    const id = current.current;
    const view = latest.current.view;
    const first = view.items[0];
    if (!joined || !first || view.earlier.items === 0) return;
    try {
      const page = await joined.earlier(first.id, count);
      if (current.current === id) dispatch({ type: "earlier", page });
    } catch {
      if (current.current === id) await joined.snapshot().catch(() => {});
    }
  }, []);
  return { ...state, refetch, loadEarlier };
}
