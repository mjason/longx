import type { SourceMessagePart } from "@assistant-ui/react";

export type Citation = {
  url: string;
  title: string;
  number: number;
  start?: number;
  end?: number;
};

export function sourceUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return ["https:", "http:"].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

/** Only message-local annotations; search result order is never a ref-id map. */
export function citationsOf(value: unknown): Citation[] {
  if (!Array.isArray(value)) return [];
  const numbers = new Map<string, number>();
  return value.flatMap(raw => {
    if (!raw || typeof raw !== "object") return [];
    const url = sourceUrl(raw.url);
    if (!url) return [];
    if (!numbers.has(url)) numbers.set(url, numbers.size + 1);
    const offset = Number.isSafeInteger(raw.offset) && raw.offset >= 0 ? raw.offset : 0;
    const start = raw.start_index;
    const end = raw.end_index;
    return [{
      url, title: typeof raw.title === "string" && raw.title.trim() ? raw.title : url,
      number: numbers.get(url)!,
      ...(Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && end > start
        ? { start: offset + start, end: offset + end } : {}),
    }];
  });
}

export function citationSources(id: string, citations: Citation[]): SourceMessagePart[] {
  return [...new Map(citations.map(c => [c.url, c])).values()].map(c => ({
    type: "source", sourceType: "url", id: `${id}:source:${c.number}`,
    url: c.url, title: c.title, providerMetadata: { longx: { number: c.number } },
  }));
}
