// The client half of Longx.Agent.ThreadState: a snapshot (with `seq`) and
// the events after it, folded with the same rules as the server's Store so
// both sides agree on what a thread looks like. Pure; DOM-free.

export type CodexItem = { id: string; type: string; turnId?: string } & Record<string, unknown>;
export type PendingRequest = { id: unknown; method: string; params: Record<string, unknown> };

/** The turn's plan (codex's update_plan tool): steps with pending / inProgress / completed. */
export type PlanStep = { step: string; status: "pending" | "inProgress" | "completed" };
export type TurnPlan = { turnId?: string; explanation: string | null; plan: PlanStep[] };

/** codex's goal mode: the thread's goal — while it is active codex starts the next turn by itself. */
export type ThreadGoal = {
  threadId: string;
  objective: string;
  status: "active" | "paused" | "blocked" | "usageLimited" | "budgetLimited" | "complete";
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
  items: CodexItem[];
  pending_requests: PendingRequest[];
  plan?: TurnPlan | null;
  goal?: ThreadGoal | null;
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
  plan: TurnPlan | null;
  goal: ThreadGoal | null;
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
    plan: s.plan ?? null,
    goal: s.goal ?? null,
  };
}

export function emptyView(threadId: string): ThreadView {
  return { seq: 0, threadId, thread: null, turn: null, status: null, tokenUsage: null, items: [], requests: [], plan: null, goal: null };
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

const REVIEW_FIELDS = ["turnId", "targetItemId", "action", "review", "decisionSource", "startedAtMs", "completedAtMs"] as const;

/**
 * Applies one event; anything at or before the view's seq is already in it.
 * `now` (epoch ms) stamps items as `startedAtMs` / `completedAtMs` — codex
 * only reports durations, the UI wants wall-clock timing.
 */
export function applyEvent(view: ThreadView, event: ThreadEvent, now: number = Date.now()): ThreadView {
  if (event.seq <= view.seq) return view;
  const next = { ...fold(view, event.method, event.params, now), seq: event.seq };
  return next;
}

function fold(view: ThreadView, method: string, params: Record<string, unknown>, now: number): ThreadView {
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
    case "turn/plan/updated":
      return {
        ...view,
        plan: { turnId: params["turnId"] as string | undefined, explanation: (params["explanation"] as string | null | undefined) ?? null, plan: (params["plan"] as PlanStep[] | undefined) ?? [] },
      };
    case "thread/goal/updated":
      return { ...view, goal: (params["goal"] as ThreadGoal | undefined) ?? null };
    case "thread/goal/cleared":
      return { ...view, goal: null };
    case "item/started":
    case "item/completed": {
      const item = params["item"] as CodexItem | undefined;
      if (!item?.id) return view;
      const turnId = (params["turnId"] as string | undefined) ?? item.turnId;
      const previous = view.items.find((i) => i.id === item.id);
      const stamps =
        method === "item/started"
          ? { startedAtMs: now }
          : { ...(previous?.["startedAtMs"] !== undefined ? { startedAtMs: previous["startedAtMs"] } : {}), completedAtMs: now };
      return { ...view, items: putItem(view.items, { ...item, ...(turnId ? { turnId } : {}), ...stamps }) };
    }
    // codex's automatic approval review (Guardian): no item of its own on the
    // wire, one is made here keyed by the review id — started, then the
    // verdict replaces it; `userApproved` is Longx's mark once the person
    // overrode a denial (mirrors Store.fold)
    case "item/autoApprovalReview/started":
    case "item/autoApprovalReview/completed": {
      const id = params["reviewId"] as string | undefined;
      if (!id) return view;
      const fields: Record<string, unknown> = {};
      for (const key of REVIEW_FIELDS) if (params[key] !== undefined) fields[key] = params[key];
      const turnId = typeof params["turnId"] === "string" ? params["turnId"] : undefined;
      return { ...view, items: putItem(view.items, { ...fields, id, type: "autoApprovalReview", ...(turnId ? { turnId } : {}) }) };
    }
    case "item/autoApprovalReview/userApproved": {
      const id = params["reviewId"] as string | undefined;
      const current = view.items.find((i) => i.id === id && i.type === "autoApprovalReview");
      if (!current) return view;
      return { ...view, items: putItem(view.items, { ...current, userApproved: true }) };
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

/**
 * How full the model's context is after the last turn: codex reports the
 * last turn's usage (its input is the whole conversation) and the window it
 * was told (`model_context_window`); nothing until both are known.
 */
export function contextUsage(view: ThreadView): { modelContextWindow: number; usage: { totalTokens: number; inputTokens: number; cachedInputTokens: number; outputTokens: number; reasoningTokens: number } } | null {
  const usage = view.tokenUsage;
  const window = usage?.["modelContextWindow"];
  const last = usage?.["last"] as Record<string, unknown> | undefined;
  if (typeof window !== "number" || window <= 0 || !last) return null;
  const n = (key: string) => (typeof last[key] === "number" ? (last[key] as number) : 0);
  return {
    modelContextWindow: window,
    usage: { totalTokens: n("totalTokens") || n("inputTokens") + n("outputTokens"), inputTokens: n("inputTokens"), cachedInputTokens: n("cachedInputTokens"), outputTokens: n("outputTokens"), reasoningTokens: n("reasoningOutputTokens") },
  };
}

/** The turn in flight, if any. */
export function runningTurnId(view: ThreadView): string | null {
  const turn = view.turn;
  return turn && turn["status"] === "inProgress" ? (turn["id"] as string) : null;
}
