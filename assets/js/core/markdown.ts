import remarkGfm from "remark-gfm";
import remarkCjkFriendly from "remark-cjk-friendly/parseOnly";
import remarkCjkFriendlyGfmStrikethrough from "remark-cjk-friendly-gfm-strikethrough/parseOnly";
import remarkMath from "remark-math";

// All Markdown surfaces share the same CJK delimiter rules. Keep GFM first:
// its CJK strikethrough override must be registered after remarkGfm.
// Parse-only entry points avoid loading Markdown serialization into the UI.
export const markdownPlugins = [
  remarkGfm,
  remarkCjkFriendly,
  remarkCjkFriendlyGfmStrikethrough,
];

// Preserve existing math support in chat and file previews; cards stay GFM.
export const markdownMathPlugins = [...markdownPlugins, remarkMath];
