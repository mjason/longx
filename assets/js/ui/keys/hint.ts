// A control's tooltip with its keys: "关闭标签 · ⌘W" in the installed app,
// "关闭标签 · SPC b d" in a browser tab — the first key this window has for
// the command, the space menu's only while it is on for this device.
import { keysFor } from "@/core/keys/bindings";
import { isMacPlatform } from "@/core/keys/notation";
import { currentBindings } from "@/core/keys/overrides";
import { getPreference } from "@/core/keys/preference";
import { appWindow } from "./state";

export function keysOf(command: string): string[] {
  return keysFor(command, currentBindings(), { app: appWindow(), mac: isMacPlatform() }, getPreference("spaceMenu"));
}

export function keysTitle(label: string, command: string): string {
  const hint = keysOf(command)[0];
  return hint ? `${label} · ${hint}` : label;
}
