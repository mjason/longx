// A control's tooltip with its space-menu keys: "关闭 · SPC b d". The keys
// are shown only while the space menu is on for this device.
import { hintOf } from "@/core/keys/keymap";
import { getPreference } from "@/core/keys/preference";

export function keysTitle(label: string, command: string): string {
  const hint = getPreference("spaceMenu") ? hintOf(command) : null;
  return hint ? `${label} · ${hint}` : label;
}
