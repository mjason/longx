// One file's change as GitHub draws it, with CodeMirror's merge view: the
// two versions side by side (or the old text inline above the new, for a
// phone), every line syntax-highlighted by the file's language, changed
// characters underlined, long unchanged stretches folded into a bar that
// expands on click. Read-only: this is a view of history, the editor tab
// is where a file is changed.
import { foldGutter, type LanguageSupport } from "@codemirror/language";
import { MergeView, unifiedMergeView } from "@codemirror/merge";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import { EditorView, lineNumbers } from "@codemirror/view";
import { useEffect, useRef } from "react";
import { languageFor } from "./languages";
import { editorHighlighting, editorTheme } from "./theme";
import { t } from "@/ui/strings";

export type DiffViewProps = {
  path: string;
  /** the file before the change; null when it did not exist */
  before: string | null;
  /** the file after; null when it was deleted */
  after: string | null;
  mode: "split" | "unified";
  wrap?: boolean;
  className?: string;
};

const collapse = { margin: 3, minSize: 4 };

// our tokens over the merge view's own colours: removed in the destructive
// hue, added in the success hue, both faint on the line and stronger on
// the characters that differ
const diffTheme = EditorView.theme({
  "&.cm-merge-a .cm-changedLine, .cm-deletedChunk": { backgroundColor: "color-mix(in oklab, var(--destructive) 12%, transparent)" },
  "&.cm-merge-b .cm-changedLine, .cm-inlineChangedLine": { backgroundColor: "color-mix(in oklab, var(--success) 12%, transparent)" },
  "&.cm-merge-a .cm-changedText, .cm-deletedChunk .cm-deletedText": {
    background: "linear-gradient(color-mix(in oklab, var(--destructive) 45%, transparent), color-mix(in oklab, var(--destructive) 45%, transparent)) bottom/100% 2px no-repeat",
  },
  "&.cm-merge-b .cm-changedText": {
    background: "linear-gradient(color-mix(in oklab, var(--success) 45%, transparent), color-mix(in oklab, var(--success) 45%, transparent)) bottom/100% 2px no-repeat",
  },
  "&.cm-merge-b .cm-deletedText": { background: "color-mix(in oklab, var(--destructive) 25%, transparent)" },
  "&.cm-merge-a .cm-changedLineGutter, .cm-deletedLineGutter": { background: "var(--destructive)" },
  "&.cm-merge-b .cm-changedLineGutter": { background: "var(--success)" },
  ".cm-inlineChangedLineGutter": { background: "var(--success)" },
  ".cm-collapsedLines": {
    color: "var(--muted-foreground)",
    background: "var(--muted)",
    borderTop: "1px solid var(--border)",
    borderBottom: "1px solid var(--border)",
    fontFamily: "var(--font-sans)",
    fontSize: "12px",
  },
});
// the two panes' own layout (outside the editors, so in app.css): each side
// scrolls sideways on its own for long lines, a rule between them

export function DiffView({ path, before, after, mode, wrap = false, className }: DiffViewProps) {
  const host = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const parent = host.current;
    if (!parent) return;
    const language = new Compartment();
    const base: Extension[] = [
      lineNumbers(),
      foldGutter(),
      editorTheme,
      editorHighlighting,
      diffTheme,
      language.of([]),
      EditorView.editable.of(false),
      EditorState.readOnly.of(true),
      EditorState.phrases.of({ "$ unchanged lines": t.unchangedLines }),
      wrap ? EditorView.lineWrapping : [],
    ];
    let views: EditorView[];
    let destroy: () => void;
    if (mode === "split") {
      const merge = new MergeView({
        a: { doc: before ?? "", extensions: base },
        b: { doc: after ?? "", extensions: base },
        parent,
        highlightChanges: true,
        gutter: true,
        collapseUnchanged: collapse,
      });
      views = [merge.a, merge.b];
      destroy = () => merge.destroy();
    } else {
      const view = new EditorView({
        state: EditorState.create({
          doc: after ?? "",
          extensions: [...base, unifiedMergeView({ original: before ?? "", mergeControls: false, highlightChanges: true, gutter: true, collapseUnchanged: collapse })],
        }),
        parent,
      });
      views = [view];
      destroy = () => view.destroy();
    }

    let cancelled = false;
    const description = languageFor(path);
    void description?.load().then((support: LanguageSupport) => {
      if (cancelled) return;
      for (const v of views) v.dispatch({ effects: language.reconfigure(support) });
    });
    return () => {
      cancelled = true;
      destroy();
    };
  }, [path, before, after, mode, wrap]);

  return <div ref={host} data-testid="diff-view" data-mode={mode} className={className} />;
}
