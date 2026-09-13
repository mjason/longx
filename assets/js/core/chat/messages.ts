// codex items → assistant-ui messages. One user message per userMessage
// item; everything else a turn produced becomes one assistant message whose
// parts follow the items in order. Pending approvals ride on the tool-call
// part they belong to (assistant-ui's `approval` seam). Pure; DOM-free.
import { fromThreadMessageLike, type MessageTiming, type ThreadMessage, type ThreadMessageLike } from "@assistant-ui/react";
import { runningTurnId, sameId, type CodexItem, type PendingRequest, type ThreadView } from "./thread";

export type ApprovalDecision = "accept" | "accept_for_session" | "decline";

/** The options an approval offers; the ids are what `respond` receives back. */
export const APPROVAL_OPTIONS = [
  { id: "accept", kind: "allow-once", label: "允许" },
  { id: "accept_for_session", kind: "allow-always", label: "本会话都允许" },
  { id: "decline", kind: "reject-once", label: "拒绝" },
] as const;

type Part = Exclude<ThreadMessageLike["content"], string>[number];
type ToolPart = Extract<Part, { type: "tool-call" }>;

/** The live views of a thread's sub-agents, by their codex thread id (for the nested conversations). */
export type SubViews = Record<string, ThreadView>;

/** One sub-agent as codex's `subAgentActivity` items describe it: its path, thread and latest state. */
export type SubAgent = { threadId: string; name: string; path: string; kind: string; firstItemId: string; startedAtMs?: number; completedAtMs?: number };

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
    const started = known?.startedAtMs ?? (typeof item["startedAtMs"] === "number" ? (item["startedAtMs"] as number) : undefined);
    const completed = kind === "completed" || kind === "interrupted" ? (typeof item["completedAtMs"] === "number" ? (item["completedAtMs"] as number) : undefined) : undefined;
    agents.set(threadId, {
      threadId,
      name: path.split("/").filter(Boolean).at(-1) ?? threadId,
      path,
      kind,
      firstItemId: known?.firstItemId ?? item.id,
      ...(started !== undefined ? { startedAtMs: started } : {}),
      ...(completed !== undefined ? { completedAtMs: completed } : {}),
    });
  }
  return agents;
}

export function toMessages(view: ThreadView, subviews: SubViews = {}): ThreadMessageLike[] {
  const running = runningTurnId(view);
  const approvals = approvalsByItem(view.requests);
  const agents = subagentsOf(view);
  const out: ThreadMessageLike[] = [];
  let current: { turnId: string | undefined; parts: Part[] } | null = null;

  const flush = () => {
    if (current && current.parts.length) {
      // the turn's plan leads its message; codex keeps one plan per turn
      if (view.plan && current.turnId !== undefined && view.plan.turnId === current.turnId) {
        current.parts.unshift({ type: "data-plan", data: { explanation: view.plan.explanation, steps: view.plan.plan } } as Part);
      }
      const timing = timingFor(view, current.turnId, current.parts);
      out.push({
        id: current.turnId ? `turn:${current.turnId}` : `turn:${out.length}`,
        role: "assistant",
        content: current.parts,
        status: awaitsApproval(current.parts) ? REQUIRES_ACTION : statusFor(view, current.turnId, running),
        ...(timing ? { metadata: { timing } } : {}),
      });
    }
    current = null;
  };

  for (const item of view.items) {
    if (item.type === "userMessage") {
      flush();
      out.push({ id: item.id, role: "user", content: [{ type: "text", text: userText(item) }] });
      continue;
    }
    if (!current || current.turnId !== item.turnId) {
      flush();
      current = { turnId: item.turnId, parts: [] };
    }
    const part = item.type === "subAgentActivity" ? subagentPart(item, agents, subviews) : item.type === "collabAgentToolCall" ? collabPart(item, agents) : toPart(item, approvals.get(item.id));
    if (part) current.parts.push(part);
  }
  flush();

  // an approval for an item we have not seen yet still needs a place to be answered
  for (const [itemId, request] of approvals) {
    if (!view.items.some((i) => i.id === itemId)) {
      attachPending(out, itemId, toolPart(itemId, toolNameFor(request.method), {}, undefined, request));
    }
  }
  // questions codex asks (requestUserInput) are standalone parts; the
  // renderer answers them through the runtime's extras (answerRequest)
  for (const request of view.requests) {
    if (request.method !== "item/tool/requestUserInput") continue;
    const itemId = String(request.params["itemId"] ?? request.id);
    const args = { requestId: String(request.id), questions: (request.params["questions"] as unknown[]) ?? [] };
    attachPending(out, itemId, toolPart(itemId, "requestUserInput", args, undefined, undefined));
  }
  return out;
}

// every activity of one sub-agent folds into a single `subagent` call at the
// place of its first one; the child's own conversation nests in `messages`
// (assistant-ui's MessagePartPrimitive.Messages) and a child waiting for an
// approval hands it up to the parent, which answers through the same codex
function subagentPart(item: CodexItem, agents: Map<string, SubAgent>, subviews: SubViews): ToolPart | null {
  const agent = agents.get(String(item["agentThreadId"] ?? ""));
  if (!agent || agent.firstItemId !== item.id) return null;
  const done = agent.kind === "completed" || agent.kind === "interrupted";
  const child = subviews[agent.threadId];
  const pending = child?.requests.find((r) => r.method.endsWith("/requestApproval"));
  const part = toolPart(
    agent.threadId,
    "subagent",
    { name: agent.name, path: agent.path, threadId: agent.threadId, kind: agent.kind, request: pending ? requestSummary(pending) : null },
    done ? { kind: agent.kind } : undefined,
    pending ? { ...pending, params: { ...pending.params, reason: `子 agent ${agent.name}：${approvalPrompt(pending)}` } } : undefined,
    agent.kind === "interrupted",
    undefined,
    agent.startedAtMs !== undefined ? { startedAt: agent.startedAtMs, ...(agent.completedAtMs !== undefined ? { completedAt: agent.completedAtMs } : {}) } : undefined,
  );
  if (!child) return part;
  const messages: ThreadMessage[] = toMessages(child, subviews).map((m, i) => fromThreadMessageLike(m, `${agent.threadId}:${i}`, { type: "complete", reason: "unknown" }));
  return { ...part, messages };
}

// what a child asks approval for, so the parent's card can show it
function requestSummary(request: PendingRequest): { command?: string; paths?: string[] } {
  const p = request.params;
  if (typeof p["command"] === "string") return { command: displayCommand(p["command"]) };
  const changes = Array.isArray(p["changes"]) ? (p["changes"] as { path?: string }[]) : [];
  return { paths: changes.map((c) => String(c.path ?? "")).filter(Boolean) };
}

// codex's collaboration tools (spawnAgent / sendMessage / wait / closeAgent…):
// the agents it addresses by name, the states it reports as the result
function collabPart(item: CodexItem, agents: Map<string, SubAgent>): ToolPart {
  const status = item["status"];
  const done = status === "completed" || status === "failed";
  // a `wait` names nobody up front; the states it reports (or every agent so far) say who it waited for
  const states = (item["agentsStates"] as Record<string, unknown> | undefined) ?? {};
  const named = Array.isArray(item["receiverThreadIds"]) ? (item["receiverThreadIds"] as string[]) : [];
  const receivers = named.length ? named : Object.keys(states).length ? Object.keys(states) : item["tool"] === "wait" ? [...agents.keys()] : [];
  return toolPart(
    item.id,
    "collab",
    {
      tool: item["tool"],
      prompt: item["prompt"] ?? null,
      model: item["model"] ?? null,
      agents: receivers.map((threadId) => ({ threadId, name: agents.get(threadId)?.name ?? threadId, kind: agents.get(threadId)?.kind ?? null })),
    },
    done ? { status, agentsStates: states } : undefined,
    undefined,
    status === "failed",
    undefined,
    timingOf(item),
  );
}

function attachPending(out: ThreadMessageLike[], itemId: string, part: ToolPart) {
  const last = out.at(-1);
  if (last && last.role === "assistant" && Array.isArray(last.content)) {
    out[out.length - 1] = { ...last, content: [...last.content, part], status: REQUIRES_ACTION };
  } else {
    out.push({ id: `pending:${itemId}`, role: "assistant", content: [part], status: REQUIRES_ACTION });
  }
}

// assistant-ui's MessageTiming from the turn (codex: epoch seconds) and the
// last turn's token usage; older turns keep only what the turn row knows.
function timingFor(view: ThreadView, turnId: string | undefined, parts: Part[]): MessageTiming | undefined {
  const turn = view.turn;
  if (!turn || turn["id"] !== turnId || typeof turn["startedAt"] !== "number") return undefined;
  const startedAt = (turn["startedAt"] as number) * 1000;
  const completedAt = typeof turn["completedAt"] === "number" ? (turn["completedAt"] as number) * 1000 : undefined;
  const last = (view.tokenUsage?.["last"] as { outputTokens?: number } | undefined) ?? undefined;
  const tokenCount = completedAt !== undefined && typeof last?.outputTokens === "number" ? last.outputTokens : undefined;
  const totalStreamTime = completedAt !== undefined ? completedAt - startedAt : undefined;
  return {
    streamStartTime: startedAt,
    ...(totalStreamTime !== undefined ? { totalStreamTime } : {}),
    ...(tokenCount !== undefined ? { tokenCount } : {}),
    ...(tokenCount !== undefined && totalStreamTime ? { tokensPerSecond: (tokenCount * 1000) / totalStreamTime } : {}),
    totalChunks: parts.length,
    toolCallCount: parts.filter((p) => p.type === "tool-call").length,
  };
}

// assistant-ui shows a part's approval controls only while its message
// requires action; a running message hides them.
const REQUIRES_ACTION = { type: "requires-action", reason: "interrupt" } as const;

function awaitsApproval(parts: Part[]): boolean {
  return parts.some((p) => p.type === "tool-call" && "approval" in p && p.approval !== undefined);
}

// the client stamps items when they start/complete (thread.ts); snapshot items have none
function timingOf(item: CodexItem): { startedAt: number; completedAt?: number } | undefined {
  const startedAt = item["startedAtMs"];
  if (typeof startedAt !== "number") return undefined;
  const completedAt = item["completedAtMs"];
  return typeof completedAt === "number" ? { startedAt, completedAt } : { startedAt };
}

function approvalsByItem(requests: PendingRequest[]): Map<string, PendingRequest> {
  const map = new Map<string, PendingRequest>();
  for (const r of requests) {
    const itemId = r.params["itemId"];
    if (typeof itemId === "string" && r.method.endsWith("/requestApproval")) map.set(itemId, r);
  }
  return map;
}

function toolNameFor(method: string): string {
  return method.includes("fileChange") ? "fileChange" : "commandExecution";
}

function statusFor(view: ThreadView, turnId: string | undefined, running: string | null): ThreadMessageLike["status"] {
  if (turnId && turnId === running) return { type: "running" };
  const turn = view.turn;
  if (turn && turn["id"] === turnId) {
    const s = turn["status"];
    if (s === "interrupted") return { type: "incomplete", reason: "cancelled" };
    if (s === "failed") {
      const err = turn["error"] as { message?: string } | undefined;
      return { type: "incomplete", reason: "error", error: err?.message ?? "failed" };
    }
  }
  return { type: "complete", reason: "stop" };
}

/** codex runs commands through a login shell (`zsh -lc '…'`); people want the inner command. */
export function displayCommand(command: string): string {
  const m = /^(?:\S*\/)?(?:zsh|bash|sh|fish|dash)\s+-l?c\s+(['"])([\s\S]*)\1\s*$/.exec(command);
  return m ? m[2]! : command;
}

function joined(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.filter((v) => typeof v === "string" && v).join("\n\n");
  return "";
}

export function userText(item: CodexItem): string {
  const content = item["content"];
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((c: { type?: string; text?: string }) => (c.type === "text" ? (c.text ?? "") : ""))
      .join("");
  }
  return "";
}

function toPart(item: CodexItem, approval: PendingRequest | undefined): Part | null {
  switch (item.type) {
    case "agentMessage": {
      const text = (item["text"] as string | undefined) ?? "";
      return { type: "text", text };
    }
    case "plan":
      return { type: "text", text: (item["text"] as string | undefined) ?? "" };
    case "reasoning": {
      // codex: summary/content are string[]; a bare string is ours (deltas before item/started)
      const text = joined(item["content"]) || joined(item["summary"]);
      return text ? { type: "reasoning", text } : null;
    }
    case "commandExecution": {
      const status = item["status"];
      const done = status === "completed" || status === "failed" || status === "declined";
      const exit = item["exitCode"] as number | null | undefined;
      return toolPart(
        item.id,
        "commandExecution",
        { command: displayCommand(String(item["command"] ?? "")), fullCommand: item["command"], cwd: item["cwd"] },
        done ? { status, exitCode: exit, output: item["aggregatedOutput"] ?? "", durationMs: item["durationMs"] } : undefined,
        approval,
        done && ((typeof exit === "number" && exit !== 0) || status === "failed" || status === "declined"),
        item["aggregatedOutput"],
        timingOf(item),
      );
    }
    case "fileChange": {
      const status = item["status"];
      const done = status === "completed" || status === "failed" || status === "declined";
      return toolPart(
        item.id,
        "fileChange",
        { changes: item["changes"] ?? [] },
        done ? { status, output: item["output"] ?? "" } : undefined,
        approval,
        status === "failed" || status === "declined",
        undefined,
        timingOf(item),
      );
    }
    case "webSearch":
      return toolPart(item.id, "webSearch", { query: item["query"], action: item["action"] }, item["results"] !== undefined ? { results: item["results"] } : undefined, undefined, false, undefined, timingOf(item));
    case "dynamicToolCall": {
      const status = item["status"];
      const done = status === "completed" || status === "failed";
      return toolPart(
        item.id,
        `${item["namespace"]}.${item["tool"]}`,
        (item["arguments"] as Record<string, unknown>) ?? {},
        done ? { success: item["success"], contentItems: item["contentItems"] ?? [], durationMs: item["durationMs"] } : undefined,
        undefined,
        done && item["success"] === false,
        undefined,
        timingOf(item),
      );
    }
    case "contextCompaction":
      return { type: "data-compaction", data: { id: item.id } } as Part;
    default:
      return { type: "data-codex", data: item } as Part;
  }
}

function toolPart(
  id: string,
  toolName: string,
  args: Record<string, unknown>,
  result: unknown,
  approval: PendingRequest | undefined,
  isError = false,
  artifact?: unknown,
  timing?: { startedAt: number; completedAt?: number },
): ToolPart {
  const part: ToolPart = {
    type: "tool-call",
    toolCallId: id,
    toolName,
    args: args as ToolPart["args"],
    ...(result !== undefined ? { result } : {}),
    ...(isError ? { isError: true } : {}),
    ...(artifact !== undefined ? { artifact } : {}),
    ...(timing ? { timing } : {}),
  };
  if (approval) {
    return {
      ...part,
      approval: {
        id: String(approval.id),
        prompt: approvalPrompt(approval),
        display: "select",
        options: APPROVAL_OPTIONS.map((o) => ({ ...o })),
      },
    };
  }
  return part;
}

// codex's reason when it gives one; the renderer shows the command / files itself
function approvalPrompt(request: PendingRequest): string {
  const p = request.params;
  if (typeof p["reason"] === "string" && p["reason"]) return p["reason"];
  return request.method.includes("fileChange") ? "允许修改这些文件？" : "允许执行这条命令？";
}

/** The request id (as codex knows it) for an approval id we handed to assistant-ui. */
export function requestIdFor(view: ThreadView, approvalId: string): unknown {
  return view.requests.find((r) => sameId(r.id, approvalId))?.id ?? approvalId;
}
