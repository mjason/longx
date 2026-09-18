// CodeMirror 6 as a controlled React component: `value` in, `onChange` out.
// The view is created once per mount; a new `value` from outside (a reload,
// a switch of file) replaces the document without counting as an edit; the
// language loads lazily by file name. Phones get soft wrapping so a long
// line never scrolls the page sideways.
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { bracketMatching, foldGutter, indentOnInput, type LanguageSupport } from "@codemirror/language";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { Annotation, Compartment, EditorState, type Extension } from "@codemirror/state";
import { drawSelection, EditorView, highlightActiveLine, highlightActiveLineGutter, keymap, lineNumbers } from "@codemirror/view";
import { useEffect, useRef } from "react";
import { languageFor } from "./languages";
import { editorHighlighting, editorTheme } from "./theme";

// marks a document replacement that came from `value`, not from typing
const fromOutside = Annotation.define<boolean>();

export type CodeEditorProps = {
  /** the file name, for the language */
  path: string;
  value: string;
  onChange?: (value: string) => void;
  readOnly?: boolean;
  /** soft-wrap long lines (phones) */
  wrap?: boolean;
  /** ⌘S / Ctrl+S */
  onSave?: () => void;
  /** a line (1-based) to put the cursor on and scroll into view — the agent's show_file */
  line?: number;
  className?: string;
};

export function CodeEditor({ path, value, onChange, readOnly = false, wrap = false, onSave, line, className }: CodeEditorProps) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const language = useRef(new Compartment());
  const editable = useRef(new Compartment());
  const wrapping = useRef(new Compartment());
  // the latest callbacks without rebuilding the view
  const callbacks = useRef({ onChange, onSave });
  callbacks.current = { onChange, onSave };
  // what the view holds, to tell an outside value from our own edit echoing back
  const held = useRef(value);

  useEffect(() => {
    if (!host.current) return;
    const extensions: Extension[] = [
      lineNumbers(),
      foldGutter(),
      highlightActiveLineGutter(),
      highlightActiveLine(),
      drawSelection(),
      history(),
      indentOnInput(),
      bracketMatching(),
      highlightSelectionMatches(),
      editorTheme,
      editorHighlighting,
      keymap.of([
        {
          key: "Mod-s",
          run: () => {
            callbacks.current.onSave?.();
            return true;
          },
        },
        indentWithTab,
        ...defaultKeymap,
        ...historyKeymap,
        ...searchKeymap,
      ]),
      language.current.of([]),
      editable.current.of([EditorView.editable.of(!readOnly), EditorState.readOnly.of(readOnly)]),
      wrapping.current.of(wrap ? EditorView.lineWrapping : []),
      EditorView.updateListener.of((update) => {
        if (!update.docChanged || update.transactions.some((tr) => tr.annotation(fromOutside))) return;
        const next = update.state.doc.toString();
        held.current = next;
        callbacks.current.onChange?.(next);
      }),
    ];
    const v = new EditorView({ state: EditorState.create({ doc: value, extensions }), parent: host.current });
    view.current = v;
    held.current = value;
    return () => {
      v.destroy();
      view.current = null;
    };
    // the view is built once; everything below reconfigures it in place
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // a value from outside replaces the document (no edit reported)
  useEffect(() => {
    const v = view.current;
    if (!v || value === held.current) return;
    held.current = value;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: value }, annotations: fromOutside.of(true) });
  }, [value]);

  useEffect(() => {
    view.current?.dispatch({ effects: editable.current.reconfigure([EditorView.editable.of(!readOnly), EditorState.readOnly.of(readOnly)]) });
  }, [readOnly]);

  // a line asked for from outside: the cursor there, centred (once the document is in)
  useEffect(() => {
    const v = view.current;
    if (!v || !line || line < 1) return;
    const n = Math.min(line, v.state.doc.lines);
    const pos = v.state.doc.line(n).from;
    v.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: "center" }) });
  }, [line, value]);

  useEffect(() => {
    view.current?.dispatch({ effects: wrapping.current.reconfigure(wrap ? EditorView.lineWrapping : []) });
  }, [wrap]);

  useEffect(() => {
    let cancelled = false;
    const description = languageFor(path);
    if (!description) {
      view.current?.dispatch({ effects: language.current.reconfigure([]) });
      return;
    }
    void description.load().then((support: LanguageSupport) => {
      if (!cancelled) view.current?.dispatch({ effects: language.current.reconfigure(support) });
    });
    return () => {
      cancelled = true;
    };
  }, [path]);

  return <div ref={host} data-testid="code-editor" className={className} />;
}
