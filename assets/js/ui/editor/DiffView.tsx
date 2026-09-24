// One file's change as VS Code's diff editor draws it, with CodeMirror's
// merge view: the two versions side by side (or the old text inline above
// the new, for a phone), every line syntax-highlighted by the file's
// language, lines matched first and characters compared only inside what
// changed (`lineDiff`), a changed line tinted and its changed characters
// tinted deeper, the side without lines striped, long unchanged stretches
// folded into a bar that expands on click. Read-only: this is a view of
// history, the editor tab is where a file is changed.
import { foldGutter, type LanguageSupport } from "@codemirror/language";
import { MergeView, unifiedMergeView } from "@codemirror/merge";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import { EditorView, lineNumbers } from "@codemirror/view";
import { useEffect, useRef } from "react";
import { languageFor } from "./languages";
import { lineDiff } from "./lineDiff";
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
const diffConfig = { override: lineDiff };

// VS Code's diff colours on our tokens: a changed line faintly tinted
// (removed in the destructive hue, added in the success hue), the
// characters that differ tinted deeper on top — no underline —, and
// diagonal stripes where the other side has lines this one lacks
const removedLine = "color-mix(in oklab, var(--destructive) 14%, transparent)";
const removedText = "color-mix(in oklab, var(--destructive) 30%, transparent)";
const addedLine = "color-mix(in oklab, var(--success) 14%, transparent)";
const addedText = "color-mix(in oklab, var(--success) 30%, transparent)";
const diffTheme = EditorView.theme({
  "&.cm-merge-a .cm-changedLine, .cm-deletedChunk": { backgroundColor: removedLine },
  "&.cm-merge-b .cm-changedLine, .cm-inlineChangedLine": { backgroundColor: addedLine },
  "&.cm-merge-a .cm-changedText, .cm-deletedChunk .cm-deletedText": { background: removedText, borderRadius: "2px" },
  "&.cm-merge-b .cm-changedText": { background: addedText, borderRadius: "2px" },
  "&.cm-merge-b .cm-deletedText": { background: removedText },
  ".cm-changedLineGutter, .cm-deletedLineGutter, .cm-inlineChangedLineGutter": { width: "3px" },
  "&.cm-merge-a .cm-changedLineGutter, .cm-deletedLineGutter": { background: "var(--destructive)" },
  "&.cm-merge-b .cm-changedLineGutter, .cm-inlineChangedLineGutter": { background: "var(--success)" },
  ".cm-mergeSpacer": {
    backgroundImage:
      "repeating-linear-gradient(-45deg, color-mix(in oklab, var(--muted-foreground) 22%, transparent) 0 1px, transparent 1px 7px)",
  },
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
        diffConfig,
      });
      views = [merge.a, merge.b];
      destroy = () => merge.destroy();
    } else {
      const view = new EditorView({
        state: EditorState.create({
          doc: after ?? "",
          extensions: [...base, unifiedMergeView({ original: before ?? "", mergeControls: false, highlightChanges: true, gutter: true, collapseUnchanged: collapse, diffConfig })],
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
