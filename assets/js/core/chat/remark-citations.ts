import type { PhrasingContent, Root, Text } from "mdast";
import type { Parent, Node } from "unist";
import type { Plugin } from "unified";
import type { Citation } from "./citations";

type Options = {
  citations: Citation[];
  pending: boolean;
  missing: string;
  loading: string;
};

// A remark transform, not a global string replacement: code, links, HTML and
// fenced examples are left alone. No provider-private token becomes a URL.
export const remarkCitations: Plugin<[Options], Root> = options => tree => {
  const walk = (parent: Parent) => {
    if (["code", "inlineCode", "link", "linkReference", "html"].includes(parent.type)) return;
    parent.children = parent.children.flatMap(node => {
      if (node.type !== "text") {
        if ("children" in node) walk(node as Parent);
        return [node];
      }
      const text = node as Text;
      const start = text.position?.start.offset;
      const end = text.position?.end.offset;
      // Escapes/entities can change text length. Don't guess source offsets.
      const positioned = start !== undefined && end !== undefined && end - start === text.value.length;
      const out: PhrasingContent[] = [];
      const markers = /cite(?:[^]*)?|(?:c(?:i(?:t(?:e(?:[^]*)?)?)?)?)?$/gu;
      const edits: { start: number; end: number; nodes: PhrasingContent[] }[] = [];
      const cited = new Set<Citation>();
      const link = (c: Citation): PhrasingContent => ({
        type: "link", url: c.url, title: c.title,
        children: [{ type: "text", value: `[${c.number}]` }],
      });
      for (const match of text.value.matchAll(markers)) {
        const index = match.index!;
        const complete = match[0].endsWith("");
        const sources = complete && positioned ? options.citations.filter(c =>
          c.start !== undefined && c.end !== undefined &&
          c.start <= start! + index && c.end >= start! + index + match[0].length,
        ) : [];
        const nodes: PhrasingContent[] = [];
        if (sources.length) {
          sources.forEach(c => cited.add(c));
          nodes.push(...[...new Map(sources.map(c => [c.url, c])).values()].map(link));
        } else {
          nodes.push({
            type: "text", value: options.pending ? options.loading : options.missing,
            data: {
              hName: "span",
              hProperties: { className: ["text-muted-foreground", "text-xs"], title: options.pending ? options.loading : options.missing, "data-citation-unavailable": true },
            },
          });
        }
        edits.push({ start: index, end: index + match[0].length, nodes });
      }
      // Standard Responses citations can annotate ordinary prose instead of a
      // private marker. Place the reference at its exact annotation endpoint.
      if (positioned) for (const c of options.citations) {
        if (c.end === undefined || c.end <= start! || c.end > end! || cited.has(c)) continue;
        const at = c.end - start!;
        if (!edits.some(e => e.start < at && e.end >= at)) {
          const same = edits.find(e => e.start === at && e.end === at);
          if (same) {
            if (!same.nodes.some(n => n.type === "link" && n.url === c.url)) same.nodes.push(link(c));
          } else edits.push({ start: at, end: at, nodes: [link(c)] });
        }
      }
      if (!edits.length) return [node];
      let cursor = 0;
      for (const edit of edits.sort((a, b) => a.start - b.start)) {
        if (edit.start < cursor) continue;
        if (cursor < edit.start) out.push({ type: "text", value: text.value.slice(cursor, edit.start) });
        out.push(...edit.nodes);
        cursor = edit.end;
      }
      if (cursor < text.value.length) out.push({ type: "text", value: text.value.slice(cursor) });
      return out as Node[];
    });
  };
  walk(tree);
};
