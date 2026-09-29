// A message's echo while it travels. The thread is the server's view: what
// the person sends shows only when the kernel's `item/started` for it comes
// back over the socket — a GraphQL round trip and a push later, seconds on a
// slow link, with the composer already empty. So a send is echoed at once
// after the thread's messages (ui/chat/PendingEchoes: 发送中…, or 已插入 for a
// steer, which the kernel takes up at the model's next step), and the echo
// goes when the view shows the person's message after the items it was sent
// over. A send that failed keeps its echo, in red, with the reason. The echo
// is never one of assistant-ui's messages: a message that gives way to
// another id at the same place stays in the runtime's repository as a
// phantom sibling, and the branch picker read "2 / 2". Pure.
import { userText } from "./messages";
import type { ThreadView } from "./thread";

export type PendingSend = {
  id: string;
  /** the row id of the thread it went to; null while the first message of a new chat makes one */
  threadId: string | null;
  kernelThreadId: string | null;
  text: string;
  images: string[];
  /** a new turn, or a steer into the running one */
  kind: "message" | "steer";
  /** how many items the view had when it went: the echo lasts until a matching item lands after them */
  after: number;
  at: number;
  /** why it did not go out */
  error?: string;
};

/** How a send registers its echo (the runtime keeps the list). */
export type PendingApi = {
  add: (p: Omit<PendingSend, "id" | "at">) => string;
  update: (id: string, patch: Partial<PendingSend>) => void;
  drop: (id: string) => void;
};

/**
 * The echoes the view does not show yet: the person's own user item (not an
 * agent's, not a job's) with the same words, past the items the echo was sent
 * over, settles one echo — the same words sent twice need two items. The same
 * array comes back when nothing settled (the runtime keeps its references).
 */
export function settled(pending: PendingSend[], view: ThreadView): PendingSend[] {
  const taken = new Set<string>();
  const rest = pending.filter((p) => {
    if (p.error) return true;
    if (p.kernelThreadId !== null && p.kernelThreadId !== view.threadId) return true;
    const hit = view.items
      .slice(p.after)
      .find((i) => i.type === "userMessage" && !i["from"] && !i["origin"] && !taken.has(i.id) && userText(i) === p.text);
    if (!hit) return true;
    taken.add(hit.id);
    return false;
  });
  return rest.length === pending.length ? pending : rest;
}

/** The echoes a page shows: its thread's, and those of a thread still being made. */
export function forThread(pending: PendingSend[], threadId: string | undefined): PendingSend[] {
  const mine = pending.filter((p) => p.threadId === null || p.threadId === threadId);
  return mine.length === pending.length ? pending : mine;
}
