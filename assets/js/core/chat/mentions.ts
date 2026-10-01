// `@file` mentions in the composer: the picked path goes into the text as-is
// (quoted when it has spaces) and the model reads the file itself; we keep
// the `@` so the message can show the path as a chip and the model still
// sees a plain path. Pure; DOM-free.
import type { Unstable_DirectiveFormatter, Unstable_DirectiveSegment, Unstable_TriggerItem } from "@assistant-ui/react";

// `@path` or `@"path with spaces"`, not the `@` inside an email or a bare one
const MENTION = /(^|[^\w.])@(?:"([^"\n]+)"|([^\s@"]+))/g;

// an upload the composer put in the text for the model (`fileAttachments.ts`):
// the tag and the note after it are the model's; the person sees a chip
const ATTACHMENT = /<attachment name="([^"]*)" path="([^"]*)" size="([^"]*)" \/>(（[^）]*）)?/g;

const SESSION = /(^|[^\w.])@session\(("(?:[^"\\\n]|\\.)*")\)/g;
const DELIVERY_NOTE = "（成果接收会话：请先在当前会话完成用户要求的内容，再调用 send_message，将完整正文或成果材料发送到此会话地址，由对方按其项目规范保存并回复路径。不要只发送当前项目的文件路径，也不要自行寻找或修改对方应用；收到回复后转告用户。）";

/** @ can follow Chinese prose directly; ASCII words and email local parts cannot. */
export function mentionTriggerMatch(text: string, char: string, cursor: number) {
  const prefix = text.slice(0, cursor);
  const offset = prefix.lastIndexOf(char);
  if (offset < 0 || cursor <= offset + char.length) {
    // A lone @ also offers the available recipients.
    if (offset >= 0 && cursor === offset + char.length && (offset === 0 || !/[\w.+%/@-]/.test(prefix[offset - 1]!))) {
      return { query: "", offset, endOffset: cursor };
    }
    return null;
  }
  if (offset > 0 && /[\w.+%/@-]/.test(prefix[offset - 1]!)) return null;
  const query = prefix.slice(offset + char.length);
  if (/\s/.test(query) || query.startsWith("session(")) return null;
  return { query, offset, endOffset: cursor };
}

function sessionReferences(text: string) {
  const found: { start: number; end: number; address: string }[] = [];
  for (const m of text.matchAll(SESSION)) {
    try {
      const address: unknown = JSON.parse(m[2]!);
      if (typeof address === "string" && address.length > 0 && !/[\r\n]/.test(address)) {
        found.push({ start: m.index + m[1]!.length, end: m.index + m[0].length, address });
      }
    } catch {
      // A partially typed or invalid reference is ordinary text.
    }
  }
  return found;
}

/** The selected recipient is for publishing completed work, not delegating the writing. */
export function withSessionDelivery(text: string): string {
  let result = text;
  for (const ref of sessionReferences(text).reverse()) {
    if (!text.slice(ref.end).startsWith(DELIVERY_NOTE)) {
      result = result.slice(0, ref.end) + DELIVERY_NOTE + result.slice(ref.end);
    }
  }
  return result;
}

function parseMentions(text: string, sessions: boolean): Unstable_DirectiveSegment[] {
  const out: Unstable_DirectiveSegment[] = [];
  let last = 0;
  const found: { start: number; end: number; seg: Unstable_DirectiveSegment }[] = [];
  if (sessions) {
    for (const ref of sessionReferences(text)) {
      const end = ref.end + (text.slice(ref.end).startsWith(DELIVERY_NOTE) ? DELIVERY_NOTE.length : 0);
      found.push({ start: ref.start, end, seg: { kind: "mention", type: "session", label: ref.address, id: ref.address } });
    }
  }
  for (const m of text.matchAll(MENTION)) {
    const path = m[2] ?? m[3]!;
    found.push({ start: m.index + m[1]!.length, end: m.index + m[0].length, seg: { kind: "mention", type: "file", label: path, id: path } });
  }
  for (const m of text.matchAll(ATTACHMENT)) {
    found.push({ start: m.index, end: m.index + m[0].length, seg: { kind: "mention", type: "attachment", label: `${m[1]} · ${m[3]}`, id: m[2]! } });
  }
  found.sort((a, b) => a.start - b.start);
  for (const f of found) {
    if (f.start < last) continue;
    if (f.start > last) out.push({ kind: "text", text: text.slice(last, f.start) });
    out.push(f.seg);
    last = f.end;
  }
  if (last < text.length) out.push({ kind: "text", text: text.slice(last) });
  return out;
}

export const fileFormatter: Unstable_DirectiveFormatter = {
  serialize(item) {
    return /\s/.test(item.id) ? `@"${item.id}"` : `@${item.id}`;
  },
  parse(text) {
    return parseMentions(text, false);
  },
};

export type FileMatch = { path: string; fileName: string; matchType: string };

/** the fuzzy matches (search_files) as the popover's items. */
export function fileMentionItems(matches: readonly FileMatch[]): Unstable_TriggerItem[] {
  return matches.map((m) => ({ id: m.path, type: m.matchType, label: m.path, metadata: { icon: m.matchType } }));
}

type SessionMatch = {
  threadId: string; address: string; handle: string | null; title: string | null;
  preview: string | null; state: string; onDuty: boolean;
};

/** Available recipients, independent of files, with the canonical project-prefixed address. */
export function sessionMentionItems(rows: readonly SessionMatch[], query: string, self: string | undefined, slug: string, hint = ""): Unstable_TriggerItem[] {
  const needle = query.trim().toLocaleLowerCase();
  return rows
    .filter((row) => row.threadId !== self && row.onDuty && !["archived", "unrecoverable"].includes(row.state))
    .filter((row) => [row.address, row.handle, row.title, row.preview].some((text) => text?.toLocaleLowerCase().includes(needle)))
    .slice(0, 20)
    .map((row) => {
      const address = row.address.includes(":") ? row.address : `${slug}:${row.address}`;
      return {
        id: `session:${address}`, type: "session", label: address,
        description: [row.title ?? row.preview?.slice(0, 24), hint].filter(Boolean).join(" · "),
        metadata: { address, icon: "session" },
      };
    });
}

/** Files and explicit session references stay visually distinct in user messages. */
export const mentionFormatter: Unstable_DirectiveFormatter = {
  serialize(item) {
    return item.type === "session"
      ? `@session(${JSON.stringify(item.metadata?.address ?? item.id.replace(/^session:/, ""))})`
      : fileFormatter.serialize(item);
  },
  parse: (text) => parseMentions(text, true),
};
