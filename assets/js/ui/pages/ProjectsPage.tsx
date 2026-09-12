import { FolderGit2, Plus, Settings } from "lucide-react";
import { Link } from "react-router";
import { useProjects } from "@/core/projects";
import { relativeTime } from "@/core/format";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { BottomBar, Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";

export function ProjectsPage() {
  const projects = useProjects();

  return (
    <>
      <TopBar
        title={t.projects}
        actions={
          <Link to="/settings" aria-label={t.settings} className="touch-target flex items-center justify-center rounded-md">
            <Settings className="size-5" />
          </Link>
        }
      />
      <Page>
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
        ) : (
          <ul className="grid gap-3 lg:grid-cols-2" data-testid="project-list">
            {projects.data.map((p) => (
              <li key={p.id}>
                <Link
                  to={`/p/${p.slug}`}
                  className="bg-card hover:bg-accent/40 active:bg-accent/60 block rounded-lg border p-4 transition-colors"
                >
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="truncate font-medium">{p.name}</span>
                    <span className="text-muted-foreground shrink-0 text-xs">{relativeTime(p.updatedAt)}</span>
                  </div>
                  <div className="text-muted-foreground mt-1 truncate font-mono text-xs">{p.rootPath}</div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </Page>
      <BottomBar>
        <Button asChild size="lg" className="w-full lg:w-auto">
          <Link to="/new">
            <Plus /> {t.newProject}
          </Link>
        </Button>
      </BottomBar>
    </>
  );
}
