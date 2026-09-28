// The status strip's word on the space menu: how to open it, how to leave a
// text field, or how far the person got (Spacemacs' modeline).
import { formatSequence } from "@/core/keys/keymap";
import { usePreference } from "@/core/keys/preference";
import { t } from "@/ui/strings";
import { useKeysUi } from "./state";

export function KeysHint() {
  const enabled = usePreference("spaceMenu");
  const { menu, typing } = useKeysUi();
  if (!enabled) return null;
  const text = menu.open ? formatSequence([" ", ...menu.sequence]) : typing ? t.keys.typingHint : t.keys.idleHint;
  return (
    <span className="ml-auto shrink-0 font-mono whitespace-nowrap" data-testid="keys-hint">
      {text}
    </span>
  );
}
