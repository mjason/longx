// The client half of Longx.Agent.ThreadState: a snapshot (with `seq`) and
// the events after it, folded with the same rules as the server's Store so
// both sides agree on what a thread looks like. Pure; DOM-free.

export type ThreadItem = { id: string; type: string; turnId?: string } & Record<
  string,
  unknown
>;
export type PendingRequest = {
  id: unknown;
  method: string;
  params: Record<string, unknown>;
};

/** The thread's goal (Plugs.Goal): while it is active the kernel starts the next turn by itself. */
export type ThreadGoal = {
  threadId: string;
  objective: string;
  status:
    | "active"
    | "paused"
    | "blocked"
    | "usageLimited"
    | "budgetLimited"
    | "complete";
  // why it is blocked: `rounds` / `budget` from the kernel, else the model's own sentence
  reason?: string | null;
  tokenBudget: number | null;
  tokensUsed: number;
  timeUsedSeconds: number;
  createdAt: number;
  updatedAt: number;
};

/** What ThreadChannel's join reply / "snapshot" carries (server-side key spelling). */
export type ThreadSnapshot = {
  seq: number;
  thread_id: string;
  thread: Record<string, unknown> | null;
  turn: Record<string, unknown> | null;
  status: Record<string, unknown> | null;
  token_usage: Record<string, unknown> | null;
  // every turn the store kept, by id (stamps, status, the turn's own usage)
  turns?: Record<string, Record<string, unknown>>;
  items: ThreadItem[];
  pending_requests: PendingRequest[];
  goal?: ThreadGoal | null;
  progress?: TurnProgress | null;
};

/**
 * What the model is writing right now (`turn/progress`): a call's arguments, a
 * retry after a broken stream, or the context fold's summary (`compaction` —
 * between turns too, with no turn behind it: `/compact` on an idle thread).
 */
export type TurnProgress = { kind: "toolCall" | "retry" | "compaction"; name: string; bytes: number };

export type ThreadEvent = {
  seq: number;
  method: string;
  params: Record<string, unknown>;
};

export type ThreadView = {
  seq: number;
  threadId: string;
  thread: Record<string, unknown> | null;
  turn: Record<string, unknown> | null;
  turns: Record<string, Record<string, unknown>>;
  status: Record<string, unknown> | null;
  tokenUsage: Record<string, unknown> | null;
  items: ThreadItem[];
  requests: PendingRequest[];
  goal: ThreadGoal | null;
  progress: TurnProgress | null;
};

export function fromSnapshot(s: ThreadSnapshot): ThreadView {
  return {
    seq: s.seq,
    threadId: s.thread_id,
    thread: s.thread,
    turn: s.turn,
    turns: s.turns ?? {},
    status: s.status,
    tokenUsage: s.token_usage,
    items: s.items,
    requests: s.pending_requests,
    goal: s.goal ?? null,
    progress: s.progress ?? null,
  };
}

export function emptyView(threadId: string): ThreadView {
  return {
    seq: 0,
    threadId,
    thread: null,
    turn: null,
    turns: {},
    status: null,
    tokenUsage: null,
    items: [],
    requests: [],
    goal: null,
    progress: null,
  };
}

// delta notifications → the item field they extend (mirrors Store.fold);
// reasoning fields are lists and the delta names its entry
const DELTAS: Record<string, { field: string; index?: string }> = {
  "item/agentMessage/delta": { field: "text" },
  "item/reasoning/summaryTextDelta": {
    field: "summary",
    index: "summaryIndex",
  },
  "item/reasoning/textDelta": { field: "content", index: "contentIndex" },
  "item/commandExecution/outputDelta": { field: "aggregatedOutput" },
  "item/fileChange/outputDelta": { field: "output" },
};

/**
 * Applies one event; anything at or before the view's seq is already in it.
 * `now` (epoch ms) stamps items as `startedAtMs` / `completedAtMs` — the
 * kernel only reports durations, the UI wants wall-clock timing.
 */
export function applyEvent(
  view: ThreadView,
  event: ThreadEvent,
  now: number = Date.now(),
): ThreadView {
  if (event.seq <= view.seq) return view;
  const next = {
    ...fold(view, event.method, event.params, now),
    seq: event.seq,
  };
  return next;
}

function fold(
  view: ThreadView,
  method: string,
  params: Record<string, unknown>,
  now: number,
): ThreadView {
  switch (method) {
    case "thread/started":
      return { ...view, thread: params["thread"] as Record<string, unknown> };
    case "turn/started":
    case "turn/completed": {
      const turn = params["turn"] as Record<string, unknown>;
      const id = typeof turn?.["id"] === "string" ? (turn["id"] as string) : null;
      return {
        ...view,
        turn,
        turns: id ? { ...view.turns, [id]: { ...(view.turns[id] ?? {}), ...turn } } : view.turns,
        progress: null,
      };
    }
    case "thread/status/changed":
      return { ...view, status: params["status"] as Record<string, unknown> };
    case "thread/tokenUsage/updated":
      return {
        ...view,
        tokenUsage: params["tokenUsage"] as Record<string, unknown>,
      };
    case "thread/goal/updated":
      return {
        ...view,
        goal: (params["goal"] as ThreadGoal | undefined) ?? null,
      };
    case "thread/goal/cleared":
      return { ...view, goal: null };
    case "turn/progress":
      return { ...view, progress: (params["progress"] as TurnProgress | null | undefined) ?? null };
    case "turn/model": {
      // what the turn runs on, onto the turn (the badge names it); the current one too
      const id = params["turnId"];
      if (typeof id !== "string") return view;
      const patch = { model: params["model"], modelName: params["name"], effort: params["effort"] };
      const merged = { ...(view.turns[id] ?? { id }), ...patch };
      return {
        ...view,
        turns: { ...view.turns, [id]: merged },
        turn: view.turn?.["id"] === id ? { ...view.turn, ...patch } : view.turn,
      };
    }
    case "item/started":
    case "item/completed": {
      const item = params["item"] as ThreadItem | undefined;
      if (!item?.id) return view;
      const turnId = (params["turnId"] as string | undefined) ?? item.turnId;
      const previous = view.items.find((i) => i.id === item.id);
      const stamps =
        method === "item/started"
          ? { startedAtMs: now }
          : {
              ...(previous?.["startedAtMs"] !== undefined
                ? { startedAtMs: previous["startedAtMs"] }
                : {}),
              completedAtMs: now,
            };
      return {
        ...view,
        items: putItem(view.items, {
          ...item,
          ...(turnId ? { turnId } : {}),
          ...stamps,
        }),
      };
    }
    case "thread/reverted": {
      const dropped = new Set(
        (params["turnIds"] as string[] | undefined) ?? [],
      );
      return {
        ...view,
        items: view.items.filter((i) => !i.turnId || !dropped.has(i.turnId)),
        turns: Object.fromEntries(Object.entries(view.turns).filter(([id]) => !dropped.has(id))),
      };
    }
    case "serverRequest/resolved": {
      const id = params["requestId"];
      return {
        ...view,
        requests: view.requests.filter((r) => !sameId(r.id, id)),
      };
    }
    default: {
      const spec = DELTAS[method];
      if (spec) {
        const id = params["itemId"] as string;
        const delta = params["delta"] as string;
        const index = spec.index
          ? (params[spec.index] as number | undefined)
          : undefined;
        return {
          ...view,
          items: appendDelta(view.items, id, spec.field, delta, index),
        };
      }
      // a server → client request carries its requestId; it waits for an answer
      if (
        "requestId" in params &&
        !view.requests.some((r) => sameId(r.id, params["requestId"]))
      ) {
        return {
          ...view,
          requests: [
            ...view.requests,
            { id: params["requestId"], method, params },
          ],
        };
      }
      return view;
    }
  }
}

function putItem(items: ThreadItem[], item: ThreadItem): ThreadItem[] {
  const idx = items.findIndex((i) => i.id === item.id);
  if (idx === -1) return [...items, item];
  const copy = items.slice();
  copy[idx] = item;
  return copy;
}

function appendDelta(
  items: ThreadItem[],
  id: string,
  field: string,
  delta: string,
  index?: number,
): ThreadItem[] {
  const idx = items.findIndex((i) => i.id === id);
  if (idx === -1)
    return [
      ...items,
      { id, type: "unknown", [field]: extend(undefined, delta, index) },
    ];
  const current = items[idx]!;
  const copy = items.slice();
  copy[idx] = { ...current, [field]: extend(current[field], delta, index) };
  return copy;
}

// a string field grows; a list field grows at `index` (or its last entry)
function extend(current: unknown, delta: string, index?: number): unknown {
  if (index === undefined && !Array.isArray(current))
    return ((current as string | undefined) ?? "") + delta;
  const list = Array.isArray(current)
    ? (current as string[]).slice()
    : current
      ? [String(current)]
      : [];
  const at = index ?? Math.max(list.length - 1, 0);
  while (list.length <= at) list.push("");
  list[at] = (list[at] ?? "") + delta;
  return list;
}

export function sameId(a: unknown, b: unknown): boolean {
  return a === b || String(a) === String(b);
}

/**
 * How full the model's context is after the last turn: the kernel reports
 * the last turn's usage (its input is the whole conversation) and the
 * model's window; nothing until both are known.
 */
export function contextUsage(view: ThreadView): {
  modelContextWindow: number;
  usage: {
    totalTokens: number;
    inputTokens: number;
    cachedInputTokens: number;
    outputTokens: number;
    reasoningTokens: number;
  };
} | null {
  const usage = view.tokenUsage;
  const window = usage?.["modelContextWindow"];
  const last = usage?.["last"] as Record<string, unknown> | undefined;
  if (typeof window !== "number" || window <= 0 || !last) return null;
  const n = (key: string) =>
    typeof last[key] === "number" ? (last[key] as number) : 0;
  return {
    modelContextWindow: window,
    usage: {
      totalTokens: n("totalTokens") || n("inputTokens") + n("outputTokens"),
      inputTokens: n("inputTokens"),
      cachedInputTokens: n("cachedInputTokens"),
      outputTokens: n("outputTokens"),
      reasoningTokens: n("reasoningOutputTokens"),
    },
  };
}

/** The turn in flight, if any. */
export function runningTurnId(view: ThreadView): string | null {
  const turn = view.turn;
  return turn && turn["status"] === "inProgress"
    ? (turn["id"] as string)
    : null;
}
