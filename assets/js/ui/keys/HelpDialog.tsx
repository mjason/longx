import { useTranslation } from "react-i18next";
// SPC ?: every command with the keys this window has for it — the chords
// (⌘W only in the installed app), Esc Esc and the space menu's — by group,
// what cannot run now greyed. Settings → 快捷键 changes them.
import { Link } from "react-router";
import { commandGroup } from "@/core/keys/bindings";
import { COMMANDS, GROUPS } from "@/core/keys/commands";
import { commands } from "@/core/keys/registry";
import { useBindings } from "@/core/keys/overrides";
import { useCommandsVersion } from "@/core/keys/useCommand";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { t } from "@/ui/strings";
import { keysOf } from "./hint";
import { updateKeysUi, useKeysUi } from "./state";

const TAB_GOTO = /^tab\.goto\.(\d)$/;

function Row({ title, keys, available }: { title: string; keys: string[]; available: boolean }) {
    useTranslation();
  return (
    <li className={`flex items-start gap-3 text-sm ${available ? "" : "text-muted-foreground/60"}`}>
      <span className="flex min-w-32 shrink-0 flex-wrap gap-1">
        {keys.map((k) => (
          <kbd key={k} className="bg-muted rounded px-1.5 py-0.5 font-mono text-xs">
            {k}
          </kbd>
        ))}
      </span>
      <span>
        {title}
        {available ? null : <span className="ml-1 text-xs">（{t.keys.unavailable}）</span>}
      </span>
    </li>
  );
}

export function HelpDialog() {
    useTranslation();
  const { help } = useKeysUi();
  useCommandsVersion();
  useBindings();
  const sections = [{ key: "", label: t.keys.common }, ...Object.entries(GROUPS).map(([key, label]) => ({ key, label }))];
  const rows = (group: string) =>
    Object.keys(COMMANDS)
      .filter((id) => commandGroup(id) === group && !(TAB_GOTO.test(id) && id !== "tab.goto.1"))
      .map((id) => {
        // the tabs' 1…9 are one row, as in the which-key panel
        if (id === "tab.goto.1") {
          const keys = keysOf(id).map((k) => k.replace(/1$/, "1…9"));
          const available = Array.from({ length: 9 }, (_, i) => `tab.goto.${i + 1}`).some(commands.available);
          return { id, title: t.keys.tabs, keys, available };
        }
        return { id, title: COMMANDS[id]!, keys: keysOf(id), available: commands.available(id) };
      })
      .filter((r) => r.keys.length > 0);
  return (
    <Dialog open={help} onOpenChange={(open) => updateKeysUi({ help: open })}>
      <DialogContent className="sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>{t.keys.help}</DialogTitle>
          <DialogDescription>
            {t.keys.helpHint}{" "}
            <Link to="/settings/keys" className="text-primary underline-offset-2 hover:underline" onClick={() => updateKeysUi({ help: false })}>
              {t.keys.customize}
            </Link>
          </DialogDescription>
        </DialogHeader>
        <DialogBody>
          <div className="grid gap-5 sm:grid-cols-2">
            {sections.map((section) => {
              const list = rows(section.key);
              if (list.length === 0) return null;
              return (
                <section key={section.key || "common"}>
                  <h3 className="mb-1.5 text-sm font-medium">
                    {section.key ? <kbd className="bg-muted mr-2 rounded px-1.5 py-0.5 font-mono text-xs">SPC {section.key}</kbd> : null}
                    {section.label}
                  </h3>
                  <ul className="grid gap-1">
                    {list.map((r) => (
                      <Row key={r.id} title={r.title} keys={r.keys} available={r.available} />
                    ))}
                  </ul>
                </section>
              );
            })}
          </div>
        </DialogBody>
      </DialogContent>
    </Dialog>
  );
}
