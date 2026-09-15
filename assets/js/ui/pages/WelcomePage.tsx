import { FolderGit2, FolderPlus, Search, Settings } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router";
import { relativeTime } from "@/core/format";
import { useProjects } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { BottomBar, Page, TopBar } from "@/ui/shell/Shell";
import { Logo } from "@/ui/components/Logo";
import { ThemeToggle } from "@/ui/components/ThemeToggle";
import { t } from "@/ui/strings";

/** IDEA's welcome screen: recent projects, search, one door into a project. */
export function WelcomePage() {
  const projects = useProjects();
  const [query, setQuery] = useState("");

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    const all = projects.data ?? [];
    return q ? all.filter((p) => p.name.toLowerCase().includes(q) || p.rootPath.toLowerCase().includes(q)) : all;
  }, [projects.data, query]);

  return (
    <>
      <TopBar
        title={
          <span className="flex items-center gap-2">
            <Logo size={26} /> {t.app}
          </span>
        }
        actions={
          <>
          <ThemeToggle />
          <Link to="/settings" aria-label={t.settings} className="touch-target flex items-center justify-center rounded-md">
            <Settings className="size-5" />
          </Link>
          </>
        }
      />
      <Page>
        {(projects.data?.length ?? 0) > 0 ? (
          <div className="relative mb-3">
            <Search className="text-muted-foreground pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2" />
            <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={t.searchProjects} className="h-11 pl-9" aria-label={t.searchProjects} />
          </div>
        ) : null}

        {projects.isPending ? (
          <div className="space-y-3" aria-busy="true">
            <Skeleton className="h-20 w-full" />
            <Skeleton className="h-20 w-full" />
          </div>
        ) : projects.isError ? (
          <p role="alert" className="text-destructive">{projects.error.message}</p>
        ) : projects.data.length === 0 ? (
          <div className="text-muted-foreground flex flex-col items-center gap-2 py-16 text-center">
            <FolderGit2 className="size-10 opacity-60" />
            <p className="text-foreground font-medium">{t.noProjects}</p>
            <p className="max-w-xs text-sm">{t.noProjectsHint}</p>
          </div>
        ) : shown.length === 0 ? (
          <p className="text-muted-foreground py-8 text-center text-sm">{t.noMatch}</p>
        ) : (
          <ul className="grid grid-cols-[minmax(0,1fr)] gap-3 lg:grid-cols-[repeat(2,minmax(0,1fr))]" data-testid="project-list">
            {shown.map((p) => (
              <li key={p.id}>
                <Link to={`/p/${p.slug}`} className="bg-card hover:bg-accent/40 active:bg-accent/60 flex items-center gap-3 rounded-lg border p-4 transition-colors">
                  <span className="bg-primary/15 text-primary flex size-10 shrink-0 items-center justify-center rounded-md font-semibold">
                    {initials(p.name)}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-baseline justify-between gap-3">
                      <span className="truncate font-medium">{p.name}</span>
                      <span className="text-muted-foreground shrink-0 text-xs">{relativeTime(p.updatedAt)}</span>
                    </span>
                    <span className="text-muted-foreground mt-1 block truncate font-mono text-xs">{p.rootPath}</span>
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </Page>
      <BottomBar>
        <Button asChild size="lg" className="w-full lg:w-auto">
          <Link to="/new">
            <FolderPlus /> {t.openOrCreate}
          </Link>
        </Button>
      </BottomBar>
    </>
  );
}

function initials(name: string): string {
  const words = name.trim().split(/\s+/);
  const first = words[0]?.[0] ?? "?";
  const second = words.length > 1 ? words[1]?.[0] : "";
  return (first + (second ?? "")).toUpperCase();
}
