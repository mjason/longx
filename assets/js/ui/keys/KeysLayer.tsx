// Every key the page answers to: one keydown listener (capture phase,
// before anything else sees the key) runs the pure engine (core/keys/engine)
// over the key table in force (core/keys/bindings + the person's own,
// core/keys/overrides) with the facts of the page — typing, the code editor,
// a dialog open, an IME composing, a control reached by keyboard, the
// installed app's window — and carries its action out. Chords and Esc Esc
// hold everywhere; the space menu only where it is on (外观 → 空格快捷菜单,
// never on a phone). Draws the which-key panel, the full list (SPC ?), the
// picker and the prompt the commands use.
import { lazy, Suspense, useEffect, useMemo } from "react";
import { leaderTree } from "@/core/keys/bindings";
import { CLOSED, ESC_WINDOW_MS, press } from "@/core/keys/engine";
import { isMacPlatform } from "@/core/keys/notation";
import { useBindings } from "@/core/keys/overrides";
import { usePicker } from "@/core/keys/picker";
import { usePreference } from "@/core/keys/preference";
import { usePrompt } from "@/core/keys/prompt";
import { commands } from "@/core/keys/registry";
import { modifierReleased } from "@/core/keys/release";
import { useViewport } from "@/core/viewport";
import { appWindow, isEditor, isTyping, keysUi, layerOpen, nativeSpace, updateKeysUi, useKeysUi } from "./state";
import { WhichKey } from "./WhichKey";

// the dialogs load when first opened: every page loads the entry before anything shows
const HelpDialog = lazy(async () => ({ default: (await import("./HelpDialog")).HelpDialog }));
const PickerDialog = lazy(async () => ({ default: (await import("./PickerDialog")).PickerDialog }));
const PromptDialog = lazy(async () => ({ default: (await import("./PromptDialog")).PromptDialog }));

export function KeysLayer() {
  const viewport = useViewport();
  const preference = usePreference("spaceMenu");
  const leader = preference && viewport !== "phone";
  const bindings = useBindings();
  const table = useMemo(() => ({ bindings, tree: leaderTree(bindings) }), [bindings]);
  const ui = useKeysUi();
  const picker = usePicker();
  const prompt = usePrompt();

  // the status strip's hint follows focus
  useEffect(() => {
    const sync = () => updateKeysUi({ typing: isTyping(document.activeElement) });
    sync();
    const later = () => setTimeout(sync, 0);
    document.addEventListener("focusin", sync);
    document.addEventListener("focusout", later);
    return () => {
      document.removeEventListener("focusin", sync);
      document.removeEventListener("focusout", later);
    };
  }, []);

  useEffect(() => {
    updateKeysUi({ menu: CLOSED });
    const mac = isMacPlatform();
    const app = appWindow();
    let disarm: ReturnType<typeof setTimeout> | undefined;
    const onKey = (e: KeyboardEvent) => {
      if (keysUi().recording) return;
      const active = document.activeElement;
      const before = keysUi().menu;
      const { state, action } = press(
        before,
        {
          key: e.key,
          code: e.code,
          ctrlKey: e.ctrlKey,
          metaKey: e.metaKey,
          altKey: e.altKey,
          shiftKey: e.shiftKey,
          composing: e.isComposing || e.keyCode === 229,
          typing: isTyping(active),
          editor: isEditor(active),
          layerOpen: layerOpen(),
          nativeSpace: nativeSpace(active),
          app,
          mac,
          leader,
          now: Date.now(),
        },
        table,
        commands.available,
      );
      if (state !== before) updateKeysUi({ menu: state });
      if (state.armed && state.armed !== before.armed) {
        // the hint goes when the second Esc can no longer come
        clearTimeout(disarm);
        const armed = state.armed;
        disarm = setTimeout(() => {
          if (keysUi().menu.armed === armed) updateKeysUi({ menu: { ...keysUi().menu, armed: null } });
        }, ESC_WINDOW_MS);
      }
      if (action.type === "none" || action.type === "close-pass" || action.type === "arm") return;
      e.preventDefault();
      e.stopPropagation();
      if (action.type === "run") {
        // after this key is done: a command may move focus or open a dialog
        setTimeout(() => commands.run(action.command), 0);
      } else if (action.type === "unknown") {
        updateKeysUi({ flash: keysUi().flash + 1 });
      } else if (action.type === "leave-input") {
        (active as HTMLElement | null)?.blur();
      }
    };
    const onKeyUp = (e: KeyboardEvent) => {
      if (e.key === "Control") modifierReleased();
    };
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("keyup", onKeyUp, true);
    return () => {
      clearTimeout(disarm);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("keyup", onKeyUp, true);
    };
  }, [leader, table]);

  return (
    <>
      {leader && ui.menu.open ? <WhichKey tree={table.tree} sequence={ui.menu.sequence} flash={ui.flash} /> : null}
      <Suspense fallback={null}>
        {ui.help ? <HelpDialog /> : null}
        {picker ? <PickerDialog /> : null}
        {prompt ? <PromptDialog /> : null}
      </Suspense>
    </>
  );
}
