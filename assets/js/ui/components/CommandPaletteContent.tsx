import { useTranslation } from "react-i18next";
import { useMatch, useNavigate } from "react-router";
import { COMMANDS } from "@/core/keys/commands";
import { commands } from "@/core/keys/registry";
import { useBindings } from "@/core/keys/overrides";
import { useCommandsVersion } from "@/core/keys/useCommand";
import { useProjects, useRecentThreads, useRunningThreads, useThreads } from "@/core/projects";
import { CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandShortcut } from "@/ui/components/ui/command";
import { keysOf } from "@/ui/keys/hint";
import { updateKeysUi, useKeysUi } from "@/ui/keys/state";
import { t } from "@/ui/strings";

type Conversation = { id: string; title: string | null; preview: string | null; slug: string; project?: string };

const label = (c: Conversation) => c.title || c.preview || `~${c.id.slice(-6)}`;

/**
 * The quick switcher: ⌘K or SPC :. The conversations of the project on
 * screen first (running and waiting on the person marked), then the other
 * projects' newest conversations, the projects, every command that can run
 * here with its keys (the palette teaches them), a few actions. Typing
 * filters them all (Slack's ⌘K). Desktop and tablet.
 */
export function CommandPaletteContent() {
    useTranslation();
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
          <CommandItem onSelect={() => go(slug ? `/p/${slug}/settings?scope=global` : "/settings")}>{t.settings}</CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
