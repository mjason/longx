"use client";

import { lazy, Suspense, type FC } from "react";
import type { ShikiHighlighterProps } from "react-shiki";
import { cn } from "@/lib/utils";

/**
 * Props for the SyntaxHighlighter component
 */
export type SyntaxHighlighterProps = Omit<
  ShikiHighlighterProps,
  "children" | "theme"
> & {
  theme?: ShikiHighlighterProps["theme"];
  code: string;
  /** Skips tokenization and renders the plain code while `true`. */
  streaming?: boolean;
};

// long lines wrap: a reading surface (the chat, a rendered document) is
// not an editor, and a horizontal scroll under a hidden scrollbar looked
// like a clipped line
const containerClassName =
  "aui-shiki-base [&_pre]:border-border/50 [&_pre]:bg-muted/30! [&_.line]:px-0! [&_pre]:overflow-x-auto [&_pre]:whitespace-pre-wrap [&_pre]:wrap-anywhere [&_pre]:rounded-t-none [&_pre]:rounded-b-xl [&_pre]:border [&_pre]:border-t-0 [&_pre]:p-3.5 [&_pre]:text-[13px] [&_pre]:leading-relaxed";

export const PlainCode: FC<{ code: string }> = ({ code }) => (
  <pre>
    <code>{code}</code>
  </pre>
);

// Shiki (react-shiki, its engine and grammars) loads with the first code
// block, not with the page: every page loads the entry before anything
// shows. The plain code stands in until then, as it does while a grammar loads.
const HighlightedCode = lazy(() => import("./shiki-highlighted"));

/**
 * SyntaxHighlighter component, using react-shiki
 *
 * Skips tokenization while `streaming` and renders the plain code in the
 * same container, so streaming costs no Shiki work and settling is a color
 * change rather than a layout shift.
 */
export const SyntaxHighlighter: FC<SyntaxHighlighterProps> = ({
  code,
  language,
  theme = { dark: "github-dark-default", light: "github-light-default" },
  className,
  style,
  // Inert: useShikiHighlighter output has no default styles or language label.
  addDefaultStyles: _addDefaultStyles,
  showLanguage: _showLanguage,
  delay = 150, // the part settles before smooth streaming finishes draining, so code keeps changing for a few frames
  streaming = false,
  ...options
}) => {
  const trimmed = code.trim();

  return (
    <div
      className={cn(
        containerClassName,
        streaming && "aui-shiki-streaming",
        className,
      )}
      style={style}
    >
      {streaming ? (
        <PlainCode code={trimmed} />
      ) : (
        <Suspense fallback={<PlainCode code={trimmed} />}>
          <HighlightedCode
            code={trimmed}
            language={language}
            theme={theme}
            options={{ ...options, delay }}
          />
        </Suspense>
      )}
    </div>
  );
};

SyntaxHighlighter.displayName = "SyntaxHighlighter";
