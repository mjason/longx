import type { SourceMessagePart } from "@assistant-ui/react";
import { ExternalLink } from "lucide-react";
import { sourceUrl } from "@/core/chat/citations";

/** assistant-ui's source part, shared by live and replayed messages. */
export function Source({ sourceType, url, title, providerMetadata }: SourceMessagePart) {
  const href = sourceType === "url" ? sourceUrl(url) : null;
  if (!href) return null;
  const number = providerMetadata?.longx?.number;
  return <a href={href} target="_blank" rel="noopener noreferrer"
    data-testid="message-source"
    className="text-muted-foreground hover:text-foreground my-1 me-2 inline-flex max-w-full items-center gap-1 rounded-md border px-2 py-1 text-xs"
    title={title || href}>
    <ExternalLink className="size-3 shrink-0" />
    <span className="truncate">{typeof number === "number" ? `[${number}] ` : ""}{title || href}</span>
  </a>;
}
