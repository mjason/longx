import { MessageSquarePlus } from "lucide-react";
import { Link, useNavigate, useParams } from "react-router";
import { relativeTime } from "@/core/format";
import { useStartThread, useThreads } from "@/core/projects";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";
import type { ProjectContext } from "../ProjectWindow";

/** IDEA's Project tree, for us: the project's threads. */
export function ThreadsTool({ ctx }: { ctx: ProjectContext }) {
  const threads = useThreads(ctx.id);
  const start = useStartThread(ctx.id);
  const navigate = useNavigate();
  const { threadId } = useParams();

  async function newThread() {
    const thread = await start.mutateAsync().catch(() => null);
    if (thread) navigate(`/p/${ctx.slug}/t/${thread.id}`);
  }

  return (
    <div className="flex flex-col gap-3" data-testid="threads-tool">
      <Button onClick={newThread} disabled={start.isPending} className="w-full">
        <MessageSquarePlus /> {t.newThread}
      </Button>
      {threads.isPending ? (
        <Skeleton className="h-16 w-full" />
      ) : !threads.data || threads.data.length === 0 ? (
        <p className="text-muted-foreground text-sm">{t.noThreads}</p>
      ) : (
        <ul className="divide-y rounded-lg border" data-testid="thread-list">
          {threads.data.map((th) => (
            <li key={th.id}>
              <Link
                to={`/p/${ctx.slug}/t/${th.id}`}
                aria-current={th.id === threadId ? "page" : undefined}
                className={`flex items-center gap-3 px-3 py-2 ${th.id === threadId ? "bg-accent/60" : "hover:bg-accent/40"}`}
              >
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm">{th.title ?? th.preview ?? t.untitledThread}</span>
                  <span className="text-muted-foreground text-xs">
                    {t.status[th.status] ?? th.status} · {relativeTime(th.lastActivityAt ?? th.insertedAt)}
                  </span>
                </span>
                {th.modelSlug ? <Badge variant="outline" className="shrink-0 font-mono text-[11px]">{th.modelSlug}</Badge> : null}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
