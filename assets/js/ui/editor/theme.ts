// The editor in our tokens: chrome from the shadcn variables (so it follows
// the theme without a second palette), syntax colours in the same muted
// register as the rest of the UI. One style set serves light and dark
// because every colour here is an oklch/hsl of a token or a hue with the
// token's lightness.
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorView } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";

export const editorTheme = EditorView.theme({
  "&": { backgroundColor: "var(--background)", color: "var(--foreground)", fontSize: "13px", height: "100%" },
  ".cm-scroller": { fontFamily: "var(--font-mono)", lineHeight: "1.6" },
  ".cm-content": { caretColor: "var(--primary)", padding: "8px 0" },
  ".cm-gutters": { backgroundColor: "var(--background)", color: "var(--muted-foreground)", borderRight: "1px solid var(--border)" },
  ".cm-activeLineGutter": { backgroundColor: "color-mix(in oklab, var(--primary) 8%, transparent)" },
  ".cm-activeLine": { backgroundColor: "color-mix(in oklab, var(--primary) 5%, transparent)" },
  "&.cm-focused .cm-cursor": { borderLeftColor: "var(--primary)" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {
    backgroundColor: "color-mix(in oklab, var(--primary) 22%, transparent) !important",
  },
  ".cm-matchingBracket": { backgroundColor: "color-mix(in oklab, var(--primary) 18%, transparent)", outline: "none" },
  ".cm-panels": { backgroundColor: "var(--sidebar)", color: "var(--sidebar-foreground)", borderColor: "var(--sidebar-border)" },
  ".cm-searchMatch": { backgroundColor: "color-mix(in oklab, var(--warning) 35%, transparent)" },
  ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: "color-mix(in oklab, var(--warning) 60%, transparent)" },
  ".cm-tooltip": { backgroundColor: "var(--popover)", color: "var(--popover-foreground)", border: "1px solid var(--border)", borderRadius: "8px" },
  ".cm-foldPlaceholder": { backgroundColor: "var(--muted)", color: "var(--muted-foreground)", border: "none" },
  "&.cm-focused": { outline: "none" },
});

const highlight = HighlightStyle.define([
  { tag: [t.keyword, t.controlKeyword, t.operatorKeyword, t.modifier], color: "var(--syntax-keyword)" },
  { tag: [t.definitionKeyword, t.moduleKeyword], color: "var(--syntax-keyword)" },
  { tag: [t.string, t.special(t.string), t.character], color: "var(--syntax-string)" },
  { tag: [t.number, t.bool, t.null, t.atom, t.literal], color: "var(--syntax-number)" },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--muted-foreground)", fontStyle: "italic" },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.definition(t.variableName)], color: "var(--syntax-function)" },
  { tag: [t.typeName, t.className, t.namespace, t.definition(t.typeName)], color: "var(--syntax-type)" },
  { tag: [t.propertyName, t.attributeName, t.labelName], color: "var(--syntax-property)" },
  { tag: [t.variableName, t.name], color: "var(--foreground)" },
  { tag: [t.operator, t.punctuation, t.separator, t.bracket], color: "var(--muted-foreground)" },
  { tag: [t.tagName, t.angleBracket], color: "var(--syntax-tag)" },
  { tag: [t.heading], fontWeight: "600", color: "var(--foreground)" },
  { tag: [t.emphasis], fontStyle: "italic" },
  { tag: [t.strong], fontWeight: "600" },
  { tag: [t.link, t.url], color: "var(--primary)", textDecoration: "underline" },
  { tag: [t.invalid], color: "var(--destructive)" },
  { tag: [t.meta, t.processingInstruction], color: "var(--muted-foreground)" },
]);

export const editorHighlighting = syntaxHighlighting(highlight);
