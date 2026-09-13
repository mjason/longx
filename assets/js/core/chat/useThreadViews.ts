// React glue: the live views of several codex threads at once — a thread's
// sub-agents. Each id joins its own `thread:<id>` channel (a sub-agent is
// hosted by its parent's codex, so the join works like any thread's); ids
// that disappear leave. A join that fails (the child is gone) yields no view.
import { useEffect, useReducer, useRef } from "react";
import { getSocket } from "@/core/socket";
import { createBatcher } from "./batch";
import { applyEvent, fromSnapshot, type ThreadEvent, type ThreadSnapshot, type ThreadView } from "./thread";
import { joinThreadChannel, type ThreadChannelHandle } from "./threadChannel";

type Views = Record<string, ThreadView>;
type Action = { type: "snapshot"; id: string; snapshot: ThreadSnapshot } | { type: "events"; id: string; events: ThreadEvent[] } | { type: "drop"; id: string };

function reduce(views: Views, action: Action): Views {
  switch (action.type) {
    case "snapshot":
      return { ...views, [action.id]: fromSnapshot(action.snapshot) };
    case "events": {
      const view = views[action.id];
      return view ? { ...views, [action.id]: action.events.reduce((v, event) => applyEvent(v, event), view) } : views;
    }
    case "drop": {
      if (!(action.id in views)) return views;
      const { [action.id]: _dropped, ...rest } = views;
      return rest;
    }
  }
}

/**
 * `ids` are the threads to follow; `expand` names more from a view already
 * joined (a sub-agent's own sub-agents), transitively.
 */
export function useThreadViews(ids: readonly string[], expand?: (view: ThreadView) => readonly string[]): Views {
  const [views, dispatch] = useReducer(reduce, {});
  const handles = useRef(new Map<string, ThreadChannelHandle>());
  const key = closure(ids, views, expand).join("\n");

  useEffect(() => {
    const wanted = new Set(key ? key.split("\n") : []);
    for (const [id, handle] of handles.current) {
      if (wanted.has(id)) continue;
      handle.leave();
      handles.current.delete(id);
      dispatch({ type: "drop", id });
    }
    for (const id of wanted) {
      if (handles.current.has(id)) continue;
      const events = createBatcher<ThreadEvent>((batch) => dispatch({ type: "events", id, events: batch }));
      const joined = joinThreadChannel(getSocket(), id, {
        onSnapshot: (snapshot) => {
          events.cancel();
          dispatch({ type: "snapshot", id, snapshot });
        },
        onEvent: (event) => {
          events.push(event);
          if (event.method === "thread/reverted") void joined.snapshot().catch(() => {});
        },
      });
      handles.current.set(id, { leave: () => { events.cancel(); joined.leave(); }, snapshot: joined.snapshot });
    }
  }, [key]);

  // leaving everything on unmount, not on every id change
  useEffect(() => {
    const current = handles.current;
    return () => {
      for (const handle of current.values()) handle.leave();
      current.clear();
    };
  }, []);

  return views;
}

function closure(ids: readonly string[], views: Views, expand?: (view: ThreadView) => readonly string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const queue = [...ids];
  while (queue.length) {
    const id = queue.shift()!;
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
    const view = views[id];
    if (view && expand) queue.push(...expand(view));
  }
  return out;
}
