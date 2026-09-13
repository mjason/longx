// codex items → assistant-ui messages. One user message per userMessage
// item; everything else a turn produced becomes one assistant message whose
// parts follow the items in order. Pending approvals ride on the tool-call
// part they belong to (assistant-ui's `approval` seam). Pure; DOM-free.
import type { ThreadMessageLike } from "@assistant-ui/react";
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

export function toMessages(view: ThreadView): ThreadMessageLike[] {
  const running = runningTurnId(view);
  const approvals = approvalsByItem(view.requests);
  const out: ThreadMessageLike[] = [];
  let current: { turnId: string | undefined; parts: Part[] } | null = null;

  const flush = () => {
    if (current && current.parts.length) {
      out.push({
        id: current.turnId ? `turn:${current.turnId}` : `turn:${out.length}`,
        role: "assistant",
        content: current.parts,
        status: awaitsApproval(current.parts) ? REQUIRES_ACTION : statusFor(view, current.turnId, running),
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
    const part = toPart(item, approvals.get(item.id));
    if (part) current.parts.push(part);
  }
  flush();

  // an approval for an item we have not seen yet still needs a place to be answered
  for (const [itemId, request] of approvals) {
    if (!view.items.some((i) => i.id === itemId)) {
      const part = toolPart(itemId, toolNameFor(request.method), {}, undefined, request);
      const last = out.at(-1);
      if (last && last.role === "assistant" && Array.isArray(last.content)) {
        out[out.length - 1] = { ...last, content: [...last.content, part], status: REQUIRES_ACTION };
      } else {
        out.push({ id: `pending:${itemId}`, role: "assistant", content: [part], status: REQUIRES_ACTION });
      }
    }
  }
  return out;
}

// assistant-ui shows a part's approval controls only while its message
// requires action; a running message hides them.
const REQUIRES_ACTION = { type: "requires-action", reason: "interrupt" } as const;

function awaitsApproval(parts: Part[]): boolean {
  return parts.some((p) => p.type === "tool-call" && "approval" in p && p.approval !== undefined);
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
      );
    }
    case "webSearch":
      return toolPart(item.id, "webSearch", { query: item["query"], action: item["action"] }, item["results"] !== undefined ? { results: item["results"] } : undefined, undefined);
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
      );
    }
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
): ToolPart {
  const part: ToolPart = {
    type: "tool-call",
    toolCallId: id,
    toolName,
    args: args as ToolPart["args"],
    ...(result !== undefined ? { result } : {}),
    ...(isError ? { isError: true } : {}),
    ...(artifact !== undefined ? { artifact } : {}),
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
