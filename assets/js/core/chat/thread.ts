// The client half of Longx.Codex.ThreadState: a snapshot (with `seq`) and
// the events after it, folded with the same rules as the server's Store so
// both sides agree on what a thread looks like. Pure; DOM-free.

export type CodexItem = { id: string; type: string; turnId?: string } & Record<string, unknown>;
export type PendingRequest = { id: unknown; method: string; params: Record<string, unknown> };

/** What ThreadChannel's join reply / "snapshot" carries (server-side key spelling). */
export type ThreadSnapshot = {
  seq: number;
  thread_id: string;
  thread: Record<string, unknown> | null;
  turn: Record<string, unknown> | null;
  status: Record<string, unknown> | null;
  token_usage: Record<string, unknown> | null;
  items: CodexItem[];
  pending_requests: PendingRequest[];
};

export type ThreadEvent = { seq: number; method: string; params: Record<string, unknown> };

export type ThreadView = {
  seq: number;
  threadId: string;
  thread: Record<string, unknown> | null;
  turn: Record<string, unknown> | null;
  status: Record<string, unknown> | null;
  tokenUsage: Record<string, unknown> | null;
  items: CodexItem[];
  requests: PendingRequest[];
};

export function fromSnapshot(s: ThreadSnapshot): ThreadView {
  return {
    seq: s.seq,
    threadId: s.thread_id,
    thread: s.thread,
    turn: s.turn,
    status: s.status,
    tokenUsage: s.token_usage,
    items: s.items,
    requests: s.pending_requests,
  };
}

export function emptyView(threadId: string): ThreadView {
  return { seq: 0, threadId, thread: null, turn: null, status: null, tokenUsage: null, items: [], requests: [] };
}

// delta notifications → the item field they extend (mirrors Store.fold);
// reasoning fields are lists and the delta names its entry
const DELTAS: Record<string, { field: string; index?: string }> = {
  "item/agentMessage/delta": { field: "text" },
  "item/reasoning/summaryTextDelta": { field: "summary", index: "summaryIndex" },
  "item/reasoning/textDelta": { field: "content", index: "contentIndex" },
  "item/commandExecution/outputDelta": { field: "aggregatedOutput" },
  "item/fileChange/outputDelta": { field: "output" },
  "item/plan/delta": { field: "text" },
};

/** Applies one event; anything at or before the view's seq is already in it. */
export function applyEvent(view: ThreadView, event: ThreadEvent): ThreadView {
  if (event.seq <= view.seq) return view;
  const next = { ...fold(view, event.method, event.params), seq: event.seq };
  return next;
}

function fold(view: ThreadView, method: string, params: Record<string, unknown>): ThreadView {
  switch (method) {
    case "thread/started":
      return { ...view, thread: params["thread"] as Record<string, unknown> };
    case "turn/started":
    case "turn/completed":
      return { ...view, turn: params["turn"] as Record<string, unknown> };
    case "thread/status/changed":
      return { ...view, status: params["status"] as Record<string, unknown> };
    case "thread/tokenUsage/updated":
      return { ...view, tokenUsage: params["tokenUsage"] as Record<string, unknown> };
    case "item/started":
    case "item/completed": {
      const item = params["item"] as CodexItem | undefined;
      if (!item?.id) return view;
      const turnId = (params["turnId"] as string | undefined) ?? item.turnId;
      return { ...view, items: putItem(view.items, turnId ? { ...item, turnId } : item) };
    }
    case "thread/reverted": {
      const dropped = new Set((params["turnIds"] as string[] | undefined) ?? []);
      return { ...view, items: view.items.filter((i) => !i.turnId || !dropped.has(i.turnId)) };
    }
    case "serverRequest/resolved": {
      const id = params["requestId"];
      return { ...view, requests: view.requests.filter((r) => !sameId(r.id, id)) };
    }
    default: {
      const spec = DELTAS[method];
      if (spec) {
        const id = params["itemId"] as string;
        const delta = params["delta"] as string;
        const index = spec.index ? (params[spec.index] as number | undefined) : undefined;
        return { ...view, items: appendDelta(view.items, id, spec.field, delta, index) };
      }
      // a server → client request carries its requestId; it waits for an answer
      if ("requestId" in params && !view.requests.some((r) => sameId(r.id, params["requestId"]))) {
        return { ...view, requests: [...view.requests, { id: params["requestId"], method, params }] };
      }
      return view;
    }
  }
}

function putItem(items: CodexItem[], item: CodexItem): CodexItem[] {
  const idx = items.findIndex((i) => i.id === item.id);
  if (idx === -1) return [...items, item];
  const copy = items.slice();
  copy[idx] = item;
  return copy;
}

function appendDelta(items: CodexItem[], id: string, field: string, delta: string, index?: number): CodexItem[] {
  const idx = items.findIndex((i) => i.id === id);
  if (idx === -1) return [...items, { id, type: "unknown", [field]: extend(undefined, delta, index) }];
  const current = items[idx]!;
  const copy = items.slice();
  copy[idx] = { ...current, [field]: extend(current[field], delta, index) };
  return copy;
}

// a string field grows; a list field grows at `index` (or its last entry)
function extend(current: unknown, delta: string, index?: number): unknown {
  if (index === undefined && !Array.isArray(current)) return ((current as string | undefined) ?? "") + delta;
  const list = Array.isArray(current) ? (current as string[]).slice() : current ? [String(current)] : [];
  const at = index ?? Math.max(list.length - 1, 0);
  while (list.length <= at) list.push("");
  list[at] = (list[at] ?? "") + delta;
  return list;
}

export function sameId(a: unknown, b: unknown): boolean {
  return a === b || String(a) === String(b);
}

/** The turn in flight, if any. */
export function runningTurnId(view: ThreadView): string | null {
  const turn = view.turn;
  return turn && turn["status"] === "inProgress" ? (turn["id"] as string) : null;
}
