// Every command the keys can run, by id, with the name the page shows for it
// (the which-key panel, SPC ?, the palette, Settings → 快捷键) — a command
// has a name whether or not a key is bound to it. What a command does, and
// whether it can run now, is registered by the part of the page that owns
// its state (./registry, useCommand). The space menu's groups are named here
// too: the second key of `SPC a s` is under 对话.

import i18n from "@/core/i18n";

function localizedRecord(path: string): Record<string, string> {
  return new Proxy({} as Record<string, string>, {
    get: (_target, key) => typeof key === "string" ? i18n.t(`${path}.${key}`, { defaultValue: key }) : undefined,
    ownKeys: () => Object.keys(i18n.getResourceBundle(i18n.resolvedLanguage ?? "zh-CN", "translation")?.core?.[path.split(".").at(-1)!] ?? {}),
    getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }),
  });
}

/** Labels are live localized objects so command UI follows a language change. */
export const GROUPS = localizedRecord("core.keyGroups");
export const COMMANDS = localizedRecord("core.keyCommands");

export function commandTitle(id: string): string {
  return COMMANDS[id] ?? id;
}
