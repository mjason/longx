import { lazy, Suspense } from "react";
import { useCommand } from "@/core/keys/useCommand";
import { keysUi, updateKeysUi, useKeysUi } from "@/ui/keys/state";

const Content = lazy(async () => ({
  default: (await import("./CommandPaletteContent")).CommandPaletteContent,
}));

/** Register the opener immediately; fetch the dialog only when it is opened. */
export function CommandPalette() {
  const { palette } = useKeysUi();
  useCommand("palette.open", () => updateKeysUi({ palette: !keysUi().palette }));
  return palette ? <Suspense fallback={null}><Content /></Suspense> : null;
}
