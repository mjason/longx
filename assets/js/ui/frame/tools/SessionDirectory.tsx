// The project's sessions (Longx.Projects.directory/2): every conversation
// with its address, state, goal and team — what agents see with
// `agents_directory`, for the person. The current session can be given a
// handle here, the name other agents (and watches) reach it by.
import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { useSessions, useSetThreadHandle, type SessionEntry } from "@/core/projects";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.directory;

function stateVariant(state: SessionEntry["state"]) {
  if (state === "running") return "default";
  if (state === "waiting") return "destructive";
  if (state === "idle") return "secondary";
  return "outline";
}

export function SessionDirectory({ projectId, slug }: { projectId: string; slug: string }) {
  const { threadId } = useParams();
  const navigate = useNavigate();
  const sessions = useSessions(projectId);
  const setHandle = useSetThreadHandle(projectId);
  const me = sessions.data?.find((row) => row.threadId === threadId);
  const [draft, setDraft] = useState("");
  useEffect(() => setDraft(me?.handle ?? ""), [me?.handle]);

  const save = async (handle: string | null) => {
    if (!threadId) return;
    try {
      await setHandle.mutateAsync({ threadId, handle });
    } catch (e) {
      toast.error((e as Error).message);
    }
  };

  return (
    <div className="flex flex-col gap-2" data-testid="session-directory">
      <h3 className="text-sm font-medium">{s.title}</h3>
      {sessions.isPending ? <Skeleton className="h-12 w-full" /> : null}
      {sessions.isError ? <p className="text-destructive text-xs">{sessions.error.message}</p> : null}
      {sessions.data?.length === 0 ? <p className="text-muted-foreground text-xs">{s.empty}</p> : null}
      {sessions.data && sessions.data.length > 0 ? (
        <ul className="divide-y rounded-md border">
          {sessions.data.map((row) => (
            <li key={row.threadId} data-testid="session-row">
              <button
                type="button"
                className="hover:bg-accent/40 flex w-full flex-col gap-0.5 px-3 py-2 text-left"
                aria-current={row.threadId === threadId ? "true" : undefined}
                onClick={() => navigate(`/p/${slug}/t/${row.threadId}`)}
              >
                <span className="flex items-center gap-2">
                  <code className="text-xs">{row.handle ? `@${row.handle}` : row.address}</code>
                  {row.handle?.startsWith("watch-") ? <span title={s.watchSession}>⏰</span> : null}
                  <Badge variant={stateVariant(row.state)} className="ml-auto">{s.states[row.state]}</Badge>
                </span>
                <span className="text-muted-foreground truncate text-xs">{row.title ?? row.preview ?? ""}</span>
                {row.goal ? <span className="text-muted-foreground truncate text-xs">{s.goal}: {row.goal.objective}</span> : null}
                {row.team.length > 0 ? <span className="text-muted-foreground truncate text-xs">{s.team}: {row.team.join(", ")}</span> : null}
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      {threadId && me ? (
        <form
          className="flex items-end gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            void save(draft.trim() === "" ? null : draft.trim());
          }}
        >
          <div className="grid flex-1 gap-1">
            <Label htmlFor="session-handle" className="text-xs">{s.handle}</Label>
            <Input id="session-handle" value={draft} placeholder={s.handlePlaceholder} onChange={(e) => setDraft(e.target.value)} className="h-9" />
          </div>
          <Button type="submit" size="sm" variant="outline" disabled={setHandle.isPending}>
            {s.setHandle}
          </Button>
        </form>
      ) : null}
      <p className="text-muted-foreground text-xs">{s.hint}</p>
    </div>
  );
}
