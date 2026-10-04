import { useTranslation } from "react-i18next";
import { useEffect } from "react";
import { ChevronDown, Pin } from "lucide-react";
import { Link, useMatch, useNavigate } from "react-router";
import { useProjects, useRunningThreads } from "@/core/projects";
import { noteProjectVisit, orderedProjects, quickProjects, setProjectPicker, useProjectPicker } from "@/core/projectNavigation";
import { useViewport } from "@/core/viewport";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/ui/components/ui/command";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/ui/components/ui/sheet";
import { t } from "@/ui/strings";
import type { ProjectContext } from "./ProjectWindow";

function useProjectNavigation() {
  const projects = useProjects();
  const running = useRunningThreads();
  const slug = useMatch("/p/:slug/*")?.params.slug ?? "";
  const activity = new Map<string, { running: number; waiting: number }>();
  for (const thread of running.data ?? []) {
    const counts = activity.get(thread.projectId) ?? { running: 0, waiting: 0 };
    counts.running++;
    if (thread.waiting) counts.waiting++;
    activity.set(thread.projectId, counts);
  }
  return { projects, slug, activity };
}

/** Project navigation is separate from the project's conversation/file tabs. */
export function ProjectSwitcher({ current }: { current: ProjectContext }) {
  useTranslation();
  const { projects, slug, activity } = useProjectNavigation();
  const viewport = useViewport();
  useEffect(() => { if (slug) noteProjectVisit(slug); }, [slug]);
  const candidates = projects.data?.some(p => p.slug === current.slug)
    ? projects.data
    : [...(projects.data ?? []), { ...current, pinned: false }];
  const quick = quickProjects(candidates, slug, new Set(activity.keys()));

  return (
    <nav aria-label={t.projectNavigation} data-testid="project-switcher" className="safe-top bg-sidebar border-sidebar-border flex h-12 shrink-0 items-center gap-1 border-b px-2">
      {viewport !== "desktop" ? (
        <button type="button" onClick={() => setProjectPicker(true)} className="touch-target flex min-w-0 flex-1 items-center gap-2 px-2" aria-label={t.allProjects}>
          <span className="truncate font-medium">{current.name}</span>
          <ChevronDown className="size-4 shrink-0" />
        </button>
      ) : (
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
          {quick.map(p => {
            const counts = activity.get(p.id);
            return (
              <Link key={p.id} to={`/p/${p.slug}`} aria-current={p.slug === slug ? "page" : undefined} title={p.rootPath}
                className={`flex h-9 shrink-0 items-center gap-2 rounded-md px-3 text-sm ${p.slug === slug ? "bg-sidebar-accent text-primary" : "text-muted-foreground hover:bg-sidebar-accent hover:text-foreground"}`}>
                {p.pinned ? <Pin className="size-3 shrink-0" aria-label={t.pinnedProjects} /> : null}
                <span className="max-w-40 truncate">{p.name}</span>
                {counts ? <span className={`text-xs ${counts.waiting ? "text-warning" : "text-primary"}`} aria-label={t.projectActivity(counts.running, counts.waiting)} title={t.projectActivity(counts.running, counts.waiting)}>● {counts.running}</span> : null}
              </Link>
            );
          })}
        </div>
      )}
      {viewport === "desktop" ? <button type="button" onClick={() => setProjectPicker(true)} className="touch-target flex shrink-0 items-center gap-1 px-2 text-xs">{t.allProjects}<ChevronDown className="size-3" /></button> : null}
    </nav>
  );
}

/** The same searchable selector is opened by the bar, home, and SPC p p. */
export function ProjectPicker() {
  useTranslation();
  const open = useProjectPicker();
  const { projects, slug, activity } = useProjectNavigation();
  const viewport = useViewport();
  const navigate = useNavigate();
  const all = orderedProjects(projects.data ?? []);
  const sections = [
    [t.keys.current, all.filter(p => p.slug === slug)],
    [t.pinnedProjects, all.filter(p => p.slug !== slug && p.pinned)],
    [t.activeProjects, all.filter(p => p.slug !== slug && !p.pinned && activity.has(p.id))],
    [t.recentProjects, all.filter(p => p.slug !== slug && !p.pinned && !activity.has(p.id))],
  ] as const;
  const content = (
    <Command>
      <CommandInput placeholder={t.searchProjects} aria-label={t.searchProjects} />
      <CommandList className="max-h-[65dvh]">
        <CommandEmpty>{projects.isPending ? t.keys.searching : projects.isError ? projects.error.message : t.noMatch}</CommandEmpty>
        {sections.filter(([, members]) => members.length).map(([label, members]) => (
          <CommandGroup key={label} heading={label}>
            {members.map(p => {
              const counts = activity.get(p.id);
              return (
                <CommandItem key={p.id} value={`${p.name} ${p.slug} ${p.rootPath}`} onSelect={() => { setProjectPicker(false); navigate(`/p/${p.slug}`); }}>
                  <span className="min-w-0 flex-1">
                    <span className="block truncate">{p.name}</span>
                    <span className="text-muted-foreground block truncate font-mono text-xs">{p.rootPath}</span>
                  </span>
                  {counts ? <span className={`shrink-0 text-xs ${counts.waiting ? "text-warning" : "text-primary"}`}>{t.projectActivity(counts.running, counts.waiting)}</span> : null}
                </CommandItem>
              );
            })}
          </CommandGroup>
        ))}
      </CommandList>
      <div className="border-t p-2"><button type="button" className="touch-target w-full text-left text-sm" onClick={() => { setProjectPicker(false); navigate("/new"); }}>{t.openOrCreate}</button></div>
    </Command>
  );
  return viewport === "desktop" ? (
    <Dialog open={open} onOpenChange={setProjectPicker}>
      <DialogContent className="overflow-hidden p-0">
        <DialogHeader className="sr-only"><DialogTitle>{t.allProjects}</DialogTitle><DialogDescription>{t.searchProjects}</DialogDescription></DialogHeader>
        {content}
      </DialogContent>
    </Dialog>
  ) : (
    <Sheet open={open} onOpenChange={setProjectPicker}>
      <SheetContent side="bottom" className="safe-bottom max-h-[85dvh] rounded-t-xl p-0" data-testid="project-picker-sheet">
        <SheetHeader className="sr-only"><SheetTitle>{t.allProjects}</SheetTitle><SheetDescription>{t.searchProjects}</SheetDescription></SheetHeader>
        {content}
      </SheetContent>
    </Sheet>
  );
}
