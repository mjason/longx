import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useProjects } from "@/core/projects";
import { CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/ui/components/ui/command";
import { t } from "@/ui/strings";

/** IDEA's Search Everywhere, ⌘K: projects and a few actions. Desktop only. */
export function CommandPalette() {
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();
  const projects = useProjects();

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  function go(to: string) {
    setOpen(false);
    navigate(to);
  }

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
        <CommandGroup heading={t.actions}>
          <CommandItem onSelect={() => go("/new")}>{t.openOrCreate}</CommandItem>
          <CommandItem onSelect={() => go("/settings")}>{t.settings}</CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
