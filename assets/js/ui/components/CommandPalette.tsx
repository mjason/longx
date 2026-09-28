import { useEffect } from "react";
import { useNavigate } from "react-router";
import { useProjects } from "@/core/projects";
import { commands } from "@/core/keys/registry";
import { hintOf, SPACE_TREE, type KeyNode } from "@/core/keys/keymap";
import { useCommandsVersion } from "@/core/keys/useCommand";
import { CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandShortcut } from "@/ui/components/ui/command";
import { updateKeysUi, useKeysUi } from "@/ui/keys/state";
import { t } from "@/ui/strings";

// every command of the space menu's tree, flattened, with its keys
const ALL: { id: string; label: string; hint: string }[] = [];
(function walk(nodes: KeyNode[]) {
  for (const n of nodes) {
    if (n.command) ALL.push({ id: n.command, label: n.label, hint: hintOf(n.command) ?? "" });
    else walk(n.children ?? []);
  }
})(SPACE_TREE);

/**
 * IDEA's Search Everywhere: ⌘K or SPC :. Projects, then every command that
 * can run here with its space-menu keys (the palette teaches them), then a
 * few actions. Desktop only.
 */
export function CommandPalette() {
  const { palette: open } = useKeysUi();
  const setOpen = (value: boolean) => updateKeysUi({ palette: value });
  const navigate = useNavigate();
  const projects = useProjects();
  useCommandsVersion();

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        updateKeysUi({ palette: !open });
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  function go(to: string) {
    setOpen(false);
    navigate(to);
  }

  function run(id: string) {
    setOpen(false);
    // after the dialog is gone: a command may open another or move focus
    setTimeout(() => commands.run(id), 0);
  }

  const available = ALL.filter((c) => c.id !== "palette.open" && commands.available(c.id));

  return (
    <CommandDialog open={open} onOpenChange={setOpen} title={t.commandPalette} description={t.searchEverywhere}>
      <CommandInput placeholder={t.searchEverywhere} />
      <CommandList>
        <CommandEmpty>{t.noResults}</CommandEmpty>
        <CommandGroup heading={t.projects}>
          {(projects.data ?? []).map((p) => (
            <CommandItem key={p.id} value={`${p.name} ${p.rootPath}`} onSelect={() => go(`/p/${p.slug}`)}>
              {p.name} <span className="text-muted-foreground ml-2 truncate font-mono text-xs">{p.rootPath}</span>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup heading={t.keys.commands}>
          {available.map((c) => (
            <CommandItem key={c.id} value={`${c.label} ${c.hint} ${c.id}`} onSelect={() => run(c.id)}>
              {c.label}
              <CommandShortcut className="font-mono">{c.hint}</CommandShortcut>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup heading={t.actions}>
          <CommandItem onSelect={() => go("/new")}>{t.openOrCreate}</CommandItem>
          <CommandItem onSelect={() => go("/settings")}>{t.settings}</CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
