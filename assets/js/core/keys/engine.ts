// Every key the page answers to, as a pure state machine: one key in, the
// next state and what the page should do. The page decides the facts (is
// the person typing, in the code editor, is a dialog or popover open, is an
// IME composing, is this the installed app) and carries the action out;
// everything here is testable without a DOM.
//
// - A chord (⌘K, ⌥↓, ⌘W in the app) runs what the key table binds to it
//   here and now; with nothing that can run, the key goes on to the browser.
// - Space outside a text field opens the space menu; its keys walk the tree.
// - Esc leaves a text field; pressed where a command waits on a second Esc
//   (Esc Esc — stopping a running turn) it arms it, and a second Esc within
//   ESC_WINDOW_MS runs it. Any other key disarms.
import { chordCommand, escapeCommand, type Binding } from "./bindings";
import { lookup, nodeAvailable, type KeyNode } from "./keymap";
import { eventChord, type KeyEventLike } from "./notation";

export const ESC_WINDOW_MS = 1500;

export type KeyState = { open: boolean; sequence: string[]; armed: { command: string; at: number } | null };
export const CLOSED: KeyState = { open: false, sequence: [], armed: null };

export type KeyInput = KeyEventLike & {
  /** an IME is composing: the key is the IME's */
  composing: boolean;
  /** focus is in a text field (an input, a textarea, the code editor) */
  typing: boolean;
  /** focus is in the code editor or a select: their Alt+arrows are their own */
  editor: boolean;
  /** a dialog, a popover or a menu is open: its keys are its own */
  layerOpen: boolean;
  /** focus is on a control the person reached by keyboard, which space presses */
  nativeSpace: boolean;
  /** the installed app's window: the browser keeps no key */
  app: boolean;
  mac: boolean;
  /** the space menu is on (this device's choice, not a phone) */
  leader: boolean;
  now: number;
};

export type KeyTable = { tree: KeyNode[]; bindings: Binding[] };

export type KeyAction =
  /** not ours: the browser and the page go on as usual */
  | { type: "none" }
  /** ours, nothing to do (shift pressed on its way to "T") */
  | { type: "consume" }
  | { type: "open" }
  | { type: "descend" }
  | { type: "back" }
  | { type: "close" }
  /** the menu closes and the chord goes on to the browser */
  | { type: "close-pass" }
  | { type: "run"; command: string }
  /** a key with nothing (available) under it: the menu stays and shows it */
  | { type: "unknown" }
  /** escape in a text field: focus leaves it (and a second Esc may be armed) */
  | { type: "leave-input" }
  /** a second Esc within the window runs this command; the key goes on as usual */
  | { type: "arm"; command: string };

export function press(state: KeyState, input: KeyInput, table: KeyTable, available: (id: string) => boolean): { state: KeyState; action: KeyAction } {
  const stay = (action: KeyAction) => ({ state, action });
  if (input.composing || input.key === "Process" || input.key === "Unidentified") return stay({ type: "none" });

  const ctx = { typing: input.typing, editor: input.editor, layer: input.layerOpen, app: input.app, mac: input.mac };
  const chord = eventChord(input, input.mac);
  const chorded = input.ctrlKey || input.metaKey || input.altKey;

  if (state.open) {
    if (chord === null) return stay({ type: "consume" });
    if (chorded) {
      const command = chordCommand(table.bindings, chord, ctx, available);
      return { state: CLOSED, action: command ? { type: "run", command } : { type: "close-pass" } };
    }
    if (input.key === "Escape") return { state: CLOSED, action: { type: "close" } };
    if (input.key === "Backspace") {
      return state.sequence.length === 0
        ? { state: CLOSED, action: { type: "close" } }
        : { state: { ...CLOSED, open: true, sequence: state.sequence.slice(0, -1) }, action: { type: "back" } };
    }
    const next = [...state.sequence, input.key];
    const node = lookup(table.tree, next);
    if (!node || !nodeAvailable(node, available)) return stay({ type: "unknown" });
    if (node.command) return { state: CLOSED, action: { type: "run", command: node.command } };
    return { state: { ...CLOSED, open: true, sequence: next }, action: { type: "descend" } };
  }

  // a modifier on its own changes nothing, an armed Esc included
  if (chord === null) return stay({ type: "none" });
  const disarmed = state.armed ? { ...state, armed: null } : state;

  if (input.key === "Escape" && !chorded) {
    if (input.layerOpen) return { state: disarmed, action: { type: "none" } };
    const armed = state.armed;
    if (armed && input.now - armed.at <= ESC_WINDOW_MS && available(armed.command)) {
      return { state: disarmed, action: { type: "run", command: armed.command } };
    }
    const command = escapeCommand(table.bindings, ctx, available);
    const next = { ...state, armed: command ? { command, at: input.now } : null };
    if (input.typing) return { state: next, action: { type: "leave-input" } };
    return { state: next, action: command ? { type: "arm", command } : { type: "none" } };
  }

  if (chorded) {
    const command = chordCommand(table.bindings, chord, ctx, available);
    return { state: disarmed, action: command ? { type: "run", command } : { type: "none" } };
  }

  if (input.key === " " && input.leader && !input.typing && !input.layerOpen && !input.nativeSpace && !input.shiftKey) {
    return { state: { ...CLOSED, open: true }, action: { type: "open" } };
  }
  return { state: disarmed, action: { type: "none" } };
}
