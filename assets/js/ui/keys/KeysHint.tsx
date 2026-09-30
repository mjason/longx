import { useTranslation } from "react-i18next";
// The status strip's word on the keys: a second Esc armed (再按 Esc：停止这一轮),
// how far the person got in the space menu, how to leave a text field, how
// to open the menu (Spacemacs' modeline).
import { commandTitle } from "@/core/keys/commands";
import { formatSequence } from "@/core/keys/keymap";
import { usePreference } from "@/core/keys/preference";
import { t } from "@/ui/strings";
import { useKeysUi } from "./state";

export function KeysHint() {
    useTranslation();
  const leader = usePreference("spaceMenu");
  const { menu, typing } = useKeysUi();
  const text = menu.armed
    ? t.keys.armed(commandTitle(menu.armed.command))
    : !leader
      ? null
      : menu.open
        ? formatSequence([" ", ...menu.sequence])
        : typing
          ? t.keys.typingHint
          : t.keys.idleHint;
  if (!text) return null;
  return (
    <span className={`ml-auto shrink-0 font-mono whitespace-nowrap ${menu.armed ? "text-warning" : ""}`} data-testid="keys-hint">
      {text}
    </span>
  );
}
