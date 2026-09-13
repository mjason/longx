import { useQueryClient } from "@tanstack/react-query";
import { MessageSquarePlus, Settings } from "lucide-react";
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { formatBytes, formatDuration, relativeTime } from "@/core/format";
import { joinProjectChannel, type CodexSample } from "@/core/projectChannel";
import { queryKeys, useCodexControls, useCodexInfo, useGitInfo, useProject, useStartThread, useThreads } from "@/core/projects";
import { getSocket } from "@/core/socket";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/ui/components/ui/card";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { BottomBar, Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";
import { GitCard } from "./project/GitCard";

export function ProjectPage() {
  const { slug = "" } = useParams();
  const project = useProject(slug);
  const id = project.data?.id;

  return (
    <>
      <TopBar
        title={project.data?.name ?? slug}
        back="/"
        actions={
          id ? (
            <Link to={`/p/${slug}/settings`} aria-label={t.settings} className="touch-target flex items-center justify-center rounded-md">
              <Settings className="size-5" />
            </Link>
          ) : null
        }
      />
      <Page className="space-y-4">
        {project.isPending ? (
          <Skeleton className="h-32 w-full" />
        ) : project.isError ? (
          <p role="alert" className="text-destructive">{project.error.message}</p>
        ) : (
          <ProjectBody projectId={project.data.id} slug={slug} rootPath={project.data.rootPath} />
        )}
      </Page>
    </>
  );
}

function ProjectBody({ projectId, slug, rootPath }: { projectId: string; slug: string; rootPath: string }) {
  const client = useQueryClient();
  const navigate = useNavigate();
  const git = useGitInfo(projectId);
  const codex = useCodexInfo(projectId);
  const threads = useThreads(projectId);
  const start = useStartThread(projectId);
  const controls = useCodexControls(projectId);
  const [sample, setSample] = useState<CodexSample | null>(null);

  // live: rows changed → refetch; codex up/down → refetch its card
  useEffect(
    () =>
      joinProjectChannel(getSocket(), projectId, {
        onChanged: () => client.invalidateQueries({ queryKey: queryKeys.threads(projectId) }),
        onCodex: () => client.invalidateQueries({ queryKey: queryKeys.codex(projectId) }),
        onSample: setSample,
      }),
    [client, projectId],
  );

  async function newThread() {
    const thread = await start.mutateAsync().catch(() => null);
    if (thread) navigate(`/p/${slug}/t/${thread.id}`);
  }

  const worker = codex.data?.worker as
    | { phase: string; os_pid?: number | null; turns: number; active_turns: number; started_at?: string; stats?: { rss_bytes: number; processes: number } | null }
    | null
    | undefined;

  return (
    <>
      <p className="text-muted-foreground -mt-1 truncate font-mono text-xs">{rootPath}</p>

      <GitCard git={git.data} loading={git.isPending} projectId={projectId} />

      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0">
          <CardTitle className="text-base">{t.codex}</CardTitle>
          {worker ? (
            <Badge variant={worker.phase === "ready" ? "default" : "secondary"}>
              {worker.phase === "ready" ? t.running : t.handshaking}
            </Badge>
          ) : (
            <Badge variant="outline">{t.stopped}</Badge>
          )}
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <dl className="contents">
            <dt className="text-muted-foreground">{t.memory}</dt>
            <dd className="font-mono">{formatBytes(sample?.rss_bytes ?? worker?.stats?.rss_bytes ?? 0)}</dd>
            <dt className="text-muted-foreground">{t.processes}</dt>
            <dd className="font-mono">{sample?.processes ?? worker?.stats?.processes ?? 0}</dd>
            <dt className="text-muted-foreground">{t.turns}</dt>
            <dd className="font-mono">{sample?.turns ?? worker?.turns ?? 0}</dd>
            <dt className="text-muted-foreground">{t.uptime}</dt>
            <dd className="font-mono">{sample ? formatDuration(sample.uptime_ms) : "—"}</dd>
            <dt className="text-muted-foreground">{t.home}</dt>
            <dd className="truncate font-mono text-xs" title={codex.data?.home}>{codex.data ? formatBytes(codex.data.bytes) : "—"}</dd>
          </dl>
          <div className="col-span-2 mt-2 flex gap-2">
            <Button variant="secondary" size="sm" disabled={!worker || controls.stop.isPending} onClick={() => controls.stop.mutate(true)}>
              {t.stop}
            </Button>
            <Button variant="secondary" size="sm" disabled={controls.restart.isPending} onClick={() => controls.restart.mutate()}>
              {t.restart}
            </Button>
          </div>
        </CardContent>
      </Card>

      <section>
        <h2 className="mb-2 text-sm font-medium">{t.threads}</h2>
        {threads.isPending ? (
          <Skeleton className="h-16 w-full" />
        ) : !threads.data || threads.data.length === 0 ? (
          <p className="text-muted-foreground text-sm">{t.noThreads}</p>
        ) : (
          <ul className="divide-y rounded-lg border" data-testid="thread-list">
            {threads.data.map((th) => (
              <li key={th.id}>
                <Link to={`/p/${slug}/t/${th.id}`} className="hover:bg-accent/40 flex items-center gap-3 px-4 py-3">
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm">{th.title ?? th.preview ?? th.codexThreadId}</div>
                    <div className="text-muted-foreground text-xs">
                      {t.status[th.status] ?? th.status} · {relativeTime(th.lastActivityAt ?? th.insertedAt)}
                    </div>
                  </div>
                  {th.modelSlug ? <Badge variant="outline" className="shrink-0 font-mono text-[11px]">{th.modelSlug}</Badge> : null}
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>

      <BottomBar>
        <Button size="lg" className="w-full lg:w-auto" onClick={newThread} disabled={start.isPending}>
          <MessageSquarePlus /> {t.newThread}
        </Button>
      </BottomBar>
    </>
  );
}
