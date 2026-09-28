// The space menu on the page: one keydown listener (capture phase, before
// anything else sees the key) runs the pure engine (core/keys/engine) with
// the facts of the page — is the person typing, is a dialog open, is an IME
// composing, is focus on a control reached by keyboard — and carries its
// action out. Draws the which-key panel, the full list (SPC ?), the picker
// and the prompt the commands use. Off on a phone, and when turned off in
// 外观 (the notice there says what space does).
import { lazy, Suspense, useEffect } from "react";
import { press } from "@/core/keys/engine";
import { SPACE_TREE } from "@/core/keys/keymap";
import { usePreference } from "@/core/keys/preference";
import { commands } from "@/core/keys/registry";
import { useViewport } from "@/core/viewport";
import { CLOSED } from "@/core/keys/engine";
import { usePicker } from "@/core/keys/picker";
import { usePrompt } from "@/core/keys/prompt";
import { isTyping, keysUi, layerOpen, nativeSpace, updateKeysUi, useKeysUi } from "./state";
import { WhichKey } from "./WhichKey";

// the dialogs load when first opened: every page loads the entry before anything shows
const HelpDialog = lazy(async () => ({ default: (await import("./HelpDialog")).HelpDialog }));
const PickerDialog = lazy(async () => ({ default: (await import("./PickerDialog")).PickerDialog }));
const PromptDialog = lazy(async () => ({ default: (await import("./PromptDialog")).PromptDialog }));

export function KeysLayer() {
  const viewport = useViewport();
  const preference = usePreference("spaceMenu");
  const enabled = preference && viewport !== "phone";
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
    if (!enabled) return;
    const onKey = (e: KeyboardEvent) => {
      const active = document.activeElement;
      const before = keysUi().menu;
      const { state, action } = press(
        before,
        {
          key: e.key,
          ctrl: e.ctrlKey,
          meta: e.metaKey,
          alt: e.altKey,
          composing: e.isComposing || e.keyCode === 229,
          typing: isTyping(active),
          layerOpen: layerOpen(),
          nativeSpace: nativeSpace(active),
        },
        SPACE_TREE,
        commands.available,
      );
      if (state !== before) updateKeysUi({ menu: state });
      if (action.type === "none" || action.type === "close-pass") return;
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
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [enabled]);

  return (
    <>
      {enabled && ui.menu.open ? <WhichKey sequence={ui.menu.sequence} flash={ui.flash} /> : null}
      <Suspense fallback={null}>
        {ui.help ? <HelpDialog /> : null}
        {picker ? <PickerDialog /> : null}
        {prompt ? <PromptDialog /> : null}
      </Suspense>
    </>
  );
}
