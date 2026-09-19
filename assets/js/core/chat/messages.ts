// thread items → assistant-ui messages. One user message per userMessage
// item; everything else a turn produced becomes one assistant message whose
// parts follow the items in order. A tool's ask (Context.ask) is a standalone
// `action` part on the message it belongs to. Pure; DOM-free.
import {
  fromThreadMessageLike,
  type MessageTiming,
  type ThreadMessage,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import {
  runningTurnId,
  type ThreadItem,
  type PendingRequest,
  type ThreadView,
} from "./thread";

type Part = Exclude<ThreadMessageLike["content"], string>[number];
type ToolPart = Extract<Part, { type: "tool-call" }>;

/** The live views of a thread's sub-agents, by their kernel thread id (for the nested conversations). */
export type SubViews = Record<string, ThreadView>;

/** One sub-agent as the `subAgentActivity` items describe it: its path, thread and latest state. */
export type SubAgent = {
  threadId: string;
  name: string;
  path: string;
  kind: string;
  /** the activity items that open a row: the first engagement (started / interacted) in each turn */
  rowItemIds: string[];
  /** the turns those rows are in */
  rowTurnIds: string[];
  startedAtMs?: number;
  completedAtMs?: number;
};

/** The method of a tool's ask (Context.ask): the person has to act before the tool goes on. */
export const ACTION_REQUEST = "longx/action/request";

/** The sub-agents a view mentions, in order of first appearance. */
export function subagentsOf(view: ThreadView): Map<string, SubAgent> {
  const agents = new Map<string, SubAgent>();
  for (const item of view.items) {
    if (item.type !== "subAgentActivity") continue;
    const threadId = String(item["agentThreadId"] ?? "");
    if (!threadId) continue;
    const path = String(item["agentPath"] ?? "");
    const kind = String(item["kind"] ?? "started");
    const known = agents.get(threadId);
    // a child engaged in a turn — spawned, or asked again later — gets a row
    // in that turn (one per turn); its conversation follows the latest row
    const engages = kind === "started" || kind === "interacted";
    const rowItemIds =
      engages && !(known?.rowTurnIds ?? []).includes(item.turnId ?? "")
        ? [...(known?.rowItemIds ?? []), item.id]
        : (known?.rowItemIds ?? []);
    const rowTurnIds =
      engages && !(known?.rowTurnIds ?? []).includes(item.turnId ?? "")
        ? [...(known?.rowTurnIds ?? []), item.turnId ?? ""]
        : (known?.rowTurnIds ?? []);
    const started =
      known?.startedAtMs ??
      (typeof item["startedAtMs"] === "number"
        ? (item["startedAtMs"] as number)
        : undefined);
    const completed =
      kind === "completed" || kind === "interrupted"
        ? typeof item["completedAtMs"] === "number"
          ? (item["completedAtMs"] as number)
          : undefined
        : undefined;
    agents.set(threadId, {
      threadId,
      name: path.split("/").filter(Boolean).at(-1) ?? threadId,
      path,
      kind,
      rowItemIds,
      rowTurnIds,
      ...(started !== undefined ? { startedAtMs: started } : {}),
      ...(completed !== undefined ? { completedAtMs: completed } : {}),
    });
  }
  return agents;
}

export function toMessages(
  view: ThreadView,
  subviews: SubViews = {},
): ThreadMessageLike[] {
  const running = runningTurnId(view);
  const agents = subagentsOf(view);
  const out: ThreadMessageLike[] = [];
  let current: { turnId: string | undefined; parts: Part[] } | null = null;
  // a message steered into a running turn splits its assistant message: the
  // segments after the first get an index, or they would share one id and
  // assistant-ui would keep only the last (the command before the steer vanished)
  const segments = new Map<string, number>();

  const flush = () => {
    if (current && current.parts.length) {
      const n = current.turnId ? (segments.get(current.turnId) ?? 0) : 0;
      if (current.turnId) segments.set(current.turnId, n + 1);
      const timed = timingFor(view, current.turnId, current.parts);
      out.push({
        id: current.turnId
          ? n === 0
            ? `turn:${current.turnId}`
            : `turn:${current.turnId}:${n}`
          : `turn:${out.length}`,
        role: "assistant",
        content: current.parts,
        status: statusFor(view, current.turnId, running),
        ...(timed
          ? { metadata: { timing: timed.timing, custom: { ...(timed.usage ? { usage: timed.usage } : {}), ...(timed.model ? { model: timed.model } : {}) } } }
          : {}),
      });
    }
    current = null;
  };

  for (const item of view.items) {
    if (item.type === "userMessage") {
      flush();
      const from = typeof item["from"] === "string" && item["from"] !== "" ? item["from"] : null;
      out.push({
        id: item.id,
        role: "user",
        // another agent's words: the `[agent name] ` prefix is for the model
        // (the Responses API has no agent role); the UI shows the name itself
        content: [{ type: "text", text: from ? stripAgentPrefix(userText(item), from) : userText(item) }, ...userImages(item)],
        ...(from ? { metadata: { custom: { from } } } : {}),
      });
      continue;
    }
    if (!current || current.turnId !== item.turnId) {
      flush();
      current = { turnId: item.turnId, parts: [] };
    }
    const part =
      item.type === "subAgentActivity"
        ? subagentPart(item, agents, subviews)
        : toPart(item);
    if (part) current.parts.push(part);
  }
  flush();

  // a tool asking the person to act (a login, a code) — Context.ask — is a
  // standalone part the renderer answers through the runtime's extras
  for (const request of view.requests) {
    if (request.method !== ACTION_REQUEST) continue;
    const itemId = String(request.params["itemId"] ?? request.id);
    const args = askArgs(request);
    attachPending(
      out,
      `${itemId}:ask`,
      toolPart(`${itemId}:ask`, "action", args, undefined),
    );
  }
  return out;
}

// every activity of one sub-agent folds into a single `subagent` call at the
// place of its first one; the child's own conversation nests in `messages`
// (assistant-ui's MessagePartPrimitive.Messages), a child waiting on the
// person shows it on the row
function subagentPart(
  item: ThreadItem,
  agents: Map<string, SubAgent>,
  subviews: SubViews,
): ToolPart | null {
  const agent = agents.get(String(item["agentThreadId"] ?? ""));
  if (!agent || !agent.rowItemIds.includes(item.id)) return null;
  // an earlier row (the child was asked again in a later turn): a completed
  // marker without the conversation, which lives on the latest row
  const latest = agent.rowItemIds.at(-1) === item.id;
  const kind = latest ? agent.kind : "completed";
  const done = kind === "completed" || kind === "interrupted";
  const child = latest ? subviews[agent.threadId] : undefined;
  const pending = child?.requests.find((r) => r.method === ACTION_REQUEST);
  const part = toolPart(
    latest ? agent.threadId : `${agent.threadId}:${item.id}`,
    "subagent",
    {
      name: agent.name,
      path: agent.path,
      threadId: agent.threadId,
      kind,
      request: pending
        ? { title: String(pending.params["title"] ?? "") }
        : null,
    },
    done ? { kind } : undefined,
    kind === "interrupted",
    undefined,
    agent.startedAtMs !== undefined
      ? {
          startedAt: agent.startedAtMs,
          ...(agent.completedAtMs !== undefined
            ? { completedAt: agent.completedAtMs }
            : {}),
        }
      : undefined,
  );
  if (!child) return part;
  const messages: ThreadMessage[] = toMessages(child, subviews).map((m, i) =>
    fromThreadMessageLike(m, `${agent.threadId}:${i}`, {
      type: "complete",
      reason: "unknown",
    }),
  );
  return { ...part, messages };
}

/** An ask (`longx/action/request`) as the `action` part's arguments — what `ActionTool` draws. */
export function askArgs(request: PendingRequest): Record<string, unknown> {
  return {
    requestId: String(request.id),
    title: String(request.params["title"] ?? ""),
    text: String(request.params["text"] ?? ""),
    url: typeof request.params["url"] === "string" ? request.params["url"] : null,
    fields:
      (request.params["fields"] as { id: string; label: string; secret?: boolean; required?: boolean }[] | undefined) ?? [],
    // a generative tree (prompt_user, Context.ask spec:) drawn instead of the fields
    ...(request.params["spec"] !== undefined && request.params["spec"] !== null ? { spec: request.params["spec"] } : {}),
  };
}

function attachPending(
  out: ThreadMessageLike[],
  itemId: string,
  part: ToolPart,
) {
  const last = out.at(-1);
  if (last && last.role === "assistant" && Array.isArray(last.content)) {
    out[out.length - 1] = {
      ...last,
      content: [...last.content, part],
      status: REQUIRES_ACTION,
    };
  } else {
    out.push({
      id: `pending:${itemId}`,
      role: "assistant",
      content: [part],
      status: REQUIRES_ACTION,
    });
  }
}

// assistant-ui's MessageTiming from the message's own turn (the kernel stamps
// every turn with epoch seconds and its own token usage; the view keeps them
// all), so an older turn's badge shows that turn's numbers
export type TurnUsage = {
  inputTokens?: number;
  cachedInputTokens?: number;
  outputTokens?: number;
  reasoningOutputTokens?: number;
  totalTokens?: number;
};

function turnOf(view: ThreadView, turnId: string | undefined): Record<string, unknown> | undefined {
  if (!turnId) return undefined;
  const kept = view.turns[turnId];
  const current = view.turn && view.turn["id"] === turnId ? view.turn : undefined;
  return kept && current ? { ...kept, ...current } : (kept ?? current);
}

function usageOf(view: ThreadView, turn: Record<string, unknown>): TurnUsage | undefined {
  if (turn["usage"] && typeof turn["usage"] === "object") return turn["usage"] as TurnUsage;
  // the running (or last, before the kernel stamped usage on turns) turn: the thread's last usage
  if (view.turn && view.turn["id"] === turn["id"]) return (view.tokenUsage?.["last"] as TurnUsage | undefined) ?? undefined;
  return undefined;
}

function timingFor(
  view: ThreadView,
  turnId: string | undefined,
  parts: Part[],
): { timing: MessageTiming; usage?: TurnUsage; model?: TurnModel } | undefined {
  const turn = turnOf(view, turnId);
  if (!turn || typeof turn["startedAt"] !== "number") return undefined;
  const model = modelOf(turn);
  const startedAt = (turn["startedAt"] as number) * 1000;
  const completedAt =
    typeof turn["completedAt"] === "number"
      ? (turn["completedAt"] as number) * 1000
      : undefined;
  const usage = usageOf(view, turn);
  const tokenCount =
    completedAt !== undefined && typeof usage?.outputTokens === "number"
      ? usage.outputTokens
      : undefined;
  const totalStreamTime =
    completedAt !== undefined ? completedAt - startedAt : undefined;
  return {
    timing: {
      streamStartTime: startedAt,
      ...(totalStreamTime !== undefined ? { totalStreamTime } : {}),
      ...(tokenCount !== undefined ? { tokenCount } : {}),
      ...(tokenCount !== undefined && totalStreamTime
        ? { tokensPerSecond: (tokenCount * 1000) / totalStreamTime }
        : {}),
      totalChunks: parts.length,
      toolCallCount: parts.filter((p) => p.type === "tool-call").length,
    },
    ...(usage && completedAt !== undefined ? { usage } : {}),
    ...(model ? { model } : {}),
  };
}

/** the model (and level) a turn ran on, as the kernel told it (`turn/model`) */
export type TurnModel = { slug: string; name: string | null; effort: string | null };

export function modelOf(turn: Record<string, unknown>): TurnModel | undefined {
  if (typeof turn["model"] !== "string") return undefined;
  return {
    slug: turn["model"],
    name: typeof turn["modelName"] === "string" ? turn["modelName"] : null,
    effort: typeof turn["effort"] === "string" ? turn["effort"] : null,
  };
}

// assistant-ui shows a part's controls only while its message requires action
const REQUIRES_ACTION = {
  type: "requires-action",
  reason: "interrupt",
} as const;

// the client stamps items when they start/complete (thread.ts); snapshot items have none
function timingOf(
  item: ThreadItem,
): { startedAt: number; completedAt?: number } | undefined {
  const startedAt = item["startedAtMs"];
  if (typeof startedAt !== "number") return undefined;
  const completedAt = item["completedAtMs"];
  return typeof completedAt === "number"
    ? { startedAt, completedAt }
    : { startedAt };
}

function statusFor(
  view: ThreadView,
  turnId: string | undefined,
  running: string | null,
): ThreadMessageLike["status"] {
  if (turnId && turnId === running) return { type: "running" };
  const turn = view.turn;
  if (turn && turn["id"] === turnId) {
    const s = turn["status"];
    if (s === "interrupted") return { type: "incomplete", reason: "cancelled" };
    if (s === "failed") {
      const err = turn["error"] as { message?: string } | undefined;
      return {
        type: "incomplete",
        reason: "error",
        error: err?.message ?? "failed",
      };
    }
  }
  return { type: "complete", reason: "stop" };
}

/** The kernel runs commands through a login shell (`zsh -lc '…'`); people want the inner command. */
export function displayCommand(command: string): string {
  const m =
    /^(?:\S*\/)?(?:zsh|bash|sh|fish|dash)\s+-l?c\s+(['"])([\s\S]*)\1\s*$/.exec(
      command,
    );
  return m ? m[2]! : command;
}

function joined(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value))
    return value.filter((v) => typeof v === "string" && v).join("\n\n");
  return "";
}

function stripAgentPrefix(text: string, from: string): string {
  const prefix = `[agent ${from}] `;
  return text.startsWith(prefix) ? text.slice(prefix.length) : text;
}

export function userText(item: ThreadItem): string {
  const content = item["content"];
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((c: { type?: string; text?: string }) =>
        c.type === "text" ? (c.text ?? "") : "",
      )
      .join("");
  }
  return "";
}

/** The images a user message carried (`image` parts with their data url). */
function userImages(item: ThreadItem): Part[] {
  const content = item["content"];
  if (!Array.isArray(content)) return [];
  return content.flatMap((c: { type?: string; url?: string }) =>
    c.type === "image" && typeof c.url === "string"
      ? [{ type: "image", image: c.url } as Part]
      : [],
  );
}

function toPart(item: ThreadItem): Part | null {
  switch (item.type) {
    case "agentMessage": {
      const text = (item["text"] as string | undefined) ?? "";
      return { type: "text", text };
    }
    case "reasoning": {
      // summary/content are string[]; a bare string is a delta before item/started
      const text = joined(item["content"]) || joined(item["summary"]);
      return text ? { type: "reasoning", text } : null;
    }
    case "commandExecution": {
      const status = item["status"];
      const done =
        status === "completed" || status === "failed" || status === "declined";
      const exit = item["exitCode"] as number | null | undefined;
      return toolPart(
        item.id,
        "commandExecution",
        {
          command: displayCommand(String(item["command"] ?? "")),
          fullCommand: item["command"],
          cwd: item["cwd"],
        },
        done
          ? {
              status,
              exitCode: exit,
              output: item["aggregatedOutput"] ?? "",
              durationMs: item["durationMs"],
            }
          : undefined,
        done &&
          ((typeof exit === "number" && exit !== 0) ||
            status === "failed" ||
            status === "declined"),
        item["aggregatedOutput"],
        timingOf(item),
      );
    }
    case "fileChange": {
      const status = item["status"];
      const done =
        status === "completed" || status === "failed" || status === "declined";
      return toolPart(
        item.id,
        "fileChange",
        { changes: item["changes"] ?? [] },
        done ? { status, output: item["output"] ?? "" } : undefined,
        status === "failed" || status === "declined",
        undefined,
        timingOf(item),
      );
    }
    case "webSearch":
      return toolPart(
        item.id,
        "webSearch",
        { query: item["query"], action: item["action"] },
        item["results"] !== undefined
          ? { results: item["results"] }
          : undefined,
        false,
        undefined,
        timingOf(item),
      );
    case "dynamicToolCall": {
      const status = item["status"];
      const done = status === "completed" || status === "failed";
      return toolPart(
        item.id,
        `${item["namespace"]}.${item["tool"]}`,
        (item["arguments"] as Record<string, unknown>) ?? {},
        done
          ? {
              success: item["success"],
              contentItems: item["contentItems"] ?? [],
              durationMs: item["durationMs"],
              // what a surface tool resolved (the project-relative path, a download's size)
              ...(item["details"] !== undefined ? { details: item["details"] } : {}),
            }
          : undefined,
        done && item["success"] === false,
        undefined,
        timingOf(item),
      );
    }
    case "contextCompaction":
      return { type: "data-compaction", data: { id: item.id } } as Part;
    default:
      return { type: "data-item", data: item } as Part;
  }
}

function toolPart(
  id: string,
  toolName: string,
  args: Record<string, unknown>,
  result: unknown,
  isError = false,
  artifact?: unknown,
  timing?: { startedAt: number; completedAt?: number },
): ToolPart {
  return {
    type: "tool-call",
    toolCallId: id,
    toolName,
    args: args as ToolPart["args"],
    ...(result !== undefined ? { result } : {}),
    ...(isError ? { isError: true } : {}),
    ...(artifact !== undefined ? { artifact } : {}),
    ...(timing ? { timing } : {}),
  };
}

/** What a request from a child asks of the person, for the parent's row (the ask's title). */
export function requestTitle(request: PendingRequest): string {
  return String(request.params["title"] ?? "");
}
