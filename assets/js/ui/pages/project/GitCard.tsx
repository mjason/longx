import { AlertTriangle, GitBranch } from "lucide-react";
import { shortSha } from "@/core/format";
import { useInitGit } from "@/core/projects";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/ui/components/ui/card";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

export type GitInfo = { repository: boolean; head: string | null; clean: boolean | null; changes: number; lfs: boolean };

/** Git is the safety net: no repository → a warning and a one-tap init. */
export function GitCard({ git, loading, projectId }: { git: GitInfo | undefined; loading: boolean; projectId: string }) {
  const init = useInitGit(projectId);

  return (
    <Card data-testid="git-card">
      <CardHeader className="flex-row items-center justify-between space-y-0">
        <CardTitle className="flex items-center gap-2 text-base">
          <GitBranch className="size-4" /> {t.git}
        </CardTitle>
        {git?.repository ? (
          <Badge variant={git.clean ? "default" : "secondary"}>{git.clean ? t.clean : t.dirty(git.changes)}</Badge>
        ) : null}
      </CardHeader>
      <CardContent className="text-sm">
        {loading || !git ? (
          <Skeleton className="h-6 w-2/3" />
        ) : git.repository ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
            <dt className="text-muted-foreground">{t.head}</dt>
            <dd className="font-mono">{shortSha(git.head)}</dd>
            {git.lfs ? (
              <>
                <dt className="text-muted-foreground">{t.lfs}</dt>
                <dd>✓</dd>
              </>
            ) : null}
          </dl>
        ) : (
          <div role="alert" className="flex flex-col gap-3">
            <div className="text-warning flex items-start gap-2">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              <div>
                <div className="font-medium">{t.noGit}</div>
                <div className="text-muted-foreground mt-1">{t.noGitHint}</div>
              </div>
            </div>
            <Button size="sm" className="self-start" onClick={() => init.mutate()} disabled={init.isPending}>
              {init.isPending ? t.initializing : t.initGit}
            </Button>
            {init.error ? <p className="text-destructive text-sm">{init.error.message}</p> : null}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
