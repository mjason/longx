// `@file` mentions in the composer: the picked path goes into the text as-is
// (quoted when it has spaces) and the model reads the file itself; we keep
// the `@` so the message can show the path as a chip and the model still
// sees a plain path. Pure; DOM-free.
import type { Unstable_DirectiveFormatter, Unstable_DirectiveSegment, Unstable_TriggerItem } from "@assistant-ui/react";

// `@path` or `@"path with spaces"`, not the `@` inside an email or a bare one
const MENTION = /(^|[^\w.])@(?:"([^"\n]+)"|([^\s@"]+))/g;

export const fileFormatter: Unstable_DirectiveFormatter = {
  serialize(item) {
    return /\s/.test(item.id) ? `@"${item.id}"` : `@${item.id}`;
  },
  parse(text) {
    const out: Unstable_DirectiveSegment[] = [];
    let last = 0;
    for (const m of text.matchAll(MENTION)) {
      const path = m[2] ?? m[3]!;
      const start = m.index + m[1]!.length;
      if (start > last) out.push({ kind: "text", text: text.slice(last, start) });
      out.push({ kind: "mention", type: "file", label: path, id: path });
      last = m.index + m[0].length;
    }
    if (last < text.length) out.push({ kind: "text", text: text.slice(last) });
    return out;
  },
};

export type FileMatch = { path: string; fileName: string; matchType: string };

/** the fuzzy matches (search_files) as the popover's items. */
export function fileMentionItems(matches: readonly FileMatch[]): Unstable_TriggerItem[] {
  return matches.map((m) => ({ id: m.path, type: m.matchType, label: m.path, metadata: { icon: m.matchType } }));
}

/** The formatter for the user text: `@file` chips (the only mention kind). */
export const mentionFormatter: Unstable_DirectiveFormatter = fileFormatter;
