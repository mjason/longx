"use client";

import type { ComponentProps } from "react";
import { SearchIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { field, mono, ShimmerLabel } from "./surfaces";

// Longx: results carry a url (rows are links), the "read N sources" line
// counts the real results, and the demo's visibleResults/cycle are gone.
export interface WebSearchResult {
  title: string;
  url: string;
}

export function domainOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

export function WebSearch({
  query,
  results,
  searching,
  readLabel,
  searchingLabel = "Searching",
  className,
  ...props
}: Omit<
  ComponentProps<"div">,
  "children" | "query" | "results" | "searching"
> & {
  query: string;
  results: readonly WebSearchResult[];
  searching: boolean;
  readLabel?: string;
  searchingLabel?: string;
}) {
  return (
    <div
      data-slot="web-search"
      className={cn("flex w-full max-w-xl flex-col gap-2.5", className)}
      {...props}
    >
      <span
        className={cn(
          field,
          "text-foreground/70 inline-flex w-fit max-w-full items-center gap-1.5 rounded-full px-3.5 py-2 text-xs",
        )}
      >
        <SearchIcon className="text-foreground/40 size-3 shrink-0" />
        <span className="truncate">{query}</span>
      </span>
      <div className="text-foreground/45 text-xs">
        {searching ? (
          <ShimmerLabel className="relative inline-block leading-none">
            {searchingLabel}
          </ShimmerLabel>
        ) : (
          <span className="fade-in animate-in duration-300">
            {readLabel ?? `Read ${results.length} sources`}
          </span>
        )}
      </div>
      {results.length > 0 ? (
        <div className="flex flex-col">
          {results.map((result, i) => {
            const domain = domainOf(result.url);
            return (
              <a
                key={`${i}-${result.url}`}
                href={result.url}
                target="_blank"
                rel="noreferrer"
                className="fade-in slide-in-from-bottom-1 animate-in fill-mode-both hover:bg-foreground/[0.03] -mx-2.5 flex items-center gap-2.5 rounded-xl px-2.5 py-1.5 transition-colors duration-300"
              >
                <span className="bg-foreground/[0.06] text-foreground/45 flex size-4 shrink-0 items-center justify-center rounded text-[9px] font-medium">
                  {domain.charAt(0).toUpperCase()}
                </span>
                <span className="text-foreground/90 min-w-0 flex-1 truncate text-[13.5px]">
                  {result.title || result.url}
                </span>
                <span className={cn(mono, "text-foreground/35 shrink-0")}>
                  {domain}
                </span>
              </a>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}
