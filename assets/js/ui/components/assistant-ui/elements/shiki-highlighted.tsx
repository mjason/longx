"use client";

// The highlighting half of shiki-highlighter, loaded with the first code
// block (react-shiki and Shiki's engine stay out of the entry).
import type { FC } from "react";
import { useShikiHighlighter, type ShikiHighlighterProps } from "react-shiki";
import { PlainCode, type SyntaxHighlighterProps } from "./shiki-highlighter";

const HighlightedCode: FC<{
  code: string;
  language: SyntaxHighlighterProps["language"];
  theme: NonNullable<SyntaxHighlighterProps["theme"]>;
  options: Omit<ShikiHighlighterProps, "children" | "language" | "theme">;
}> = ({ code, language, theme, options }) => {
  const highlighted = useShikiHighlighter(code, language, theme, {
    ...options,
    defaultColor: "light-dark()",
  });
  return <>{highlighted ?? <PlainCode code={code} />}</>;
};

export default HighlightedCode;
