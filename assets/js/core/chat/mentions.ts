// `@file` mentions in the composer. codex's own TUI inserts the picked path
// into the text as-is (quoted when it has spaces) and lets the model read
// the file; we keep the `@` so the message can show the path as a chip and
// the model still sees a plain path. Pure; DOM-free.
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

/** codex's fuzzy matches (search_files) as the popover's items. */
export function fileMentionItems(matches: readonly FileMatch[]): Unstable_TriggerItem[] {
  return matches.map((m) => ({ id: m.path, type: m.matchType, label: m.path, metadata: { icon: m.matchType } }));
}

// `$name` — a skill codex knows (letters, digits, `-`, `_`; never a price)
const SKILL = /(^|[^\w$])\$([A-Za-z][\w-]*)/g;

/** A skill as the popover and the adapter see it (`Skill` in core/projects). */
export type SkillRef = { name: string; description: string; shortDescription: string | null; path: string | null; enabled: boolean };

/** The enabled skills as the `$` popover's items; a pick is written as `$name`. */
export function skillMentionItems(skills: readonly SkillRef[]): Unstable_TriggerItem[] {
  return skills.filter((s) => s.enabled).map((s) => ({ id: s.name, type: "skill", label: s.name, description: s.shortDescription ?? s.description, metadata: { icon: "skill" } }));
}

/** The skills a message names, once each, known (and enabled) ones only — what rides on the turn as skill inputs. */
export function skillsIn(text: string, skills: readonly SkillRef[]): { name: string; path: string }[] {
  const out: { name: string; path: string }[] = [];
  for (const m of text.matchAll(SKILL)) {
    const name = m[2]!;
    if (out.some((s) => s.name === name)) continue;
    const skill = skills.find((s) => s.name === name && s.enabled && s.path);
    if (skill) out.push({ name, path: skill.path! });
  }
  return out;
}

/** One formatter for the user text: `@file` and `$skill` chips. */
export const mentionFormatter: Unstable_DirectiveFormatter = {
  serialize(item) {
    return item.type === "skill" ? `$${item.id}` : fileFormatter.serialize(item);
  },
  parse(text) {
    // split on skills first, then let the file formatter handle each text run
    const out: Unstable_DirectiveSegment[] = [];
    let last = 0;
    const flush = (upTo: number) => {
      if (upTo > last) out.push(...fileFormatter.parse(text.slice(last, upTo)));
    };
    for (const m of text.matchAll(SKILL)) {
      const start = m.index + m[1]!.length;
      flush(start);
      out.push({ kind: "mention", type: "skill", label: m[2]!, id: m[2]! });
      last = m.index + m[0].length;
    }
    flush(text.length);
    return out;
  },
};
