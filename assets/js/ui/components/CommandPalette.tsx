import { useEffect, useMemo } from "react";
import { useMatch, useNavigate } from "react-router";
import { COMMANDS } from "@/core/keys/commands";
import { commands } from "@/core/keys/registry";
import { useBindings } from "@/core/keys/overrides";
import { useCommand, useCommandsVersion } from "@/core/keys/useCommand";
import { useProjects, useRecentThreads, useRunningThreads, useThreads } from "@/core/projects";
import { CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandShortcut } from "@/ui/components/ui/command";
import { keysOf } from "@/ui/keys/hint";
import { keysUi, updateKeysUi, useKeysUi } from "@/ui/keys/state";
import { t } from "@/ui/strings";
import { shellCanRenderSurface, shellSurface } from "@/ui/shell/longxShell";

type Conversation = { id: string; title: string | null; preview: string | null; slug: string; project?: string };

const label = (c: Conversation) => c.title || c.preview || `~${c.id.slice(-6)}`;

/**
 * The quick switcher: ⌘K or SPC :. The conversations of the project on
 * screen first (running and waiting on the person marked), then the other
 * projects' newest conversations, the projects, every command that can run
 * here with its keys (the palette teaches them), a few actions. Typing
 * filters them all (Slack's ⌘K). Desktop and tablet.
 */
export function CommandPalette() {
  const { palette: open } = useKeysUi();
  const setOpen = (value: boolean) => updateKeysUi({ palette: value });
  const navigate = useNavigate();
  const projects = useProjects();
  const slug = useMatch("/p/:slug/*")?.params.slug;
  const here = projects.data?.find((p) => p.slug === slug);
  const threads = useThreads(here?.id);
  const running = useRunningThreads(3000, open);
  const recent = useRecentThreads(open);
  useCommandsVersion();
  useBindings();
  // ⌘K / SPC : — registered here, with the page, not with the lazily loaded commands; again closes it
  useCommand("palette.open", () => updateKeysUi({ palette: !keysUi().palette }));

  function go(to: string) {
    setOpen(false);
    navigate(to);
  }

  function run(id: string) {
    setOpen(false);
    // after the dialog is gone: a command may open another or move focus
    setTimeout(() => commands.run(id), 0);
  }

  const state = new Map((running.data ?? []).map((r) => [r.id, r.waiting ? "waiting" : "running"] as const));
  const mine: Conversation[] = (threads.data ?? []).map((r) => ({ id: r.id, title: r.title, preview: r.preview, slug: slug ?? "" }));
  const others: Conversation[] = (recent.data ?? [])
    .filter((r) => r.projectSlug !== slug)
    .map((r) => ({ id: r.id, title: r.title, preview: r.preview, slug: r.projectSlug, project: r.projectName }));
  const available = Object.keys(COMMANDS).filter((id) => id !== "palette.open" && !id.startsWith("tab.goto.") && commands.available(id));
  const nativeItems = useMemo(() => [
    ...mine.map((c) => ({ id: `thread:${c.slug}:${c.id}`, label: label(c), detail: c.project, group: c.project ? t.keys.recentThreads : t.keys.threadsHere, status: state.get(c.id) })),
    ...(projects.data ?? []).map((p) => ({ id: `project:${p.slug}`, label: p.name, detail: p.rootPath, group: t.projects })),
    ...available.map((id) => ({ id: `command:${id}`, label: COMMANDS[id]!, shortcut: keysOf(id)[0] ?? "", group: t.keys.commands })),
    { id: "action:new", label: t.openOrCreate, group: t.actions },
    { id: "action:settings", label: t.settings, group: t.actions },
  ], [mine, projects.data, available, state]);
  const nativeItemsKey = JSON.stringify(nativeItems);

  useEffect(() => {
    if (!open || !shellCanRenderSurface()) return;
    let live = true;
    void shellSurface({ surface: "menu", title: t.commandPalette, placement: "center", data: { searchable: true, placeholder: t.searchEverywhere, items: nativeItems } }).then((result) => {
      if (!live) return;
      setOpen(false);
      const id = typeof result === "string" ? result : (result as { id?: unknown } | null)?.id;
      if (typeof id !== "string") return;
      const item = nativeItems.find((candidate) => candidate.id === id);
      if (!item) return;
      if (id.startsWith("thread:")) {
        const [, projectSlug, threadId] = id.split(":");
        go(`/p/${projectSlug}/t/${threadId}`);
      } else if (id.startsWith("project:")) go(`/p/${id.slice("project:".length)}`);
      else if (id.startsWith("command:")) setTimeout(() => commands.run(id.slice("command:".length)), 0);
      else if (id === "action:new") go("/new");
      else if (id === "action:settings") go("/settings");
    });
    return () => { live = false; };
  }, [open, nativeItemsKey]);

  const row = (c: Conversation) => {
    const s = state.get(c.id);
    return (
      <CommandItem key={c.id} value={`${label(c)} ${c.preview ?? ""} ${c.project ?? ""} ${c.id}`} onSelect={() => go(`/p/${c.slug}/t/${c.id}`)}>
        <span className="min-w-0 truncate">{label(c)}</span>
        {c.project ? <span className="text-muted-foreground ml-2 shrink-0 truncate text-xs">{c.project}</span> : null}
        {s ? (
          <span className={`ml-auto shrink-0 text-xs ${s === "waiting" ? "text-warning" : "text-primary"}`} data-state={s}>
            {s === "waiting" ? t.keys.waiting : t.keys.running}
          </span>
        ) : null}
      </CommandItem>
    );
  };

  if (open && shellCanRenderSurface()) return null;
  return (
    <CommandDialog open={open} onOpenChange={setOpen} title={t.commandPalette} description={t.searchEverywhere}>
      <CommandInput placeholder={t.searchEverywhere} />
      <CommandList>
        <CommandEmpty>{t.noResults}</CommandEmpty>
        {mine.length > 0 ? <CommandGroup heading={t.keys.threadsHere}>{mine.map(row)}</CommandGroup> : null}
        {others.length > 0 ? <CommandGroup heading={t.keys.recentThreads}>{others.map(row)}</CommandGroup> : null}
        <CommandGroup heading={t.projects}>
          {(projects.data ?? []).map((p) => (
            <CommandItem key={p.id} value={`${p.name} ${p.rootPath}`} onSelect={() => go(`/p/${p.slug}`)}>
              {p.name} <span className="text-muted-foreground ml-2 truncate font-mono text-xs">{p.rootPath}</span>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup heading={t.keys.commands}>
          {available.map((id) => {
            const hint = keysOf(id)[0] ?? "";
            return (
              <CommandItem key={id} value={`${COMMANDS[id]} ${hint} ${id}`} onSelect={() => run(id)}>
                {COMMANDS[id]}
                <CommandShortcut className="font-mono">{hint}</CommandShortcut>
              </CommandItem>
            );
          })}
        </CommandGroup>
        <CommandGroup heading={t.actions}>
          <CommandItem onSelect={() => go("/new")}>{t.openOrCreate}</CommandItem>
          <CommandItem onSelect={() => go("/settings")}>{t.settings}</CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
