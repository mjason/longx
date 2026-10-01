// The project's sessions (Longx.Projects.directory/2): every conversation
// with its address, state, goal and team — what agents see with
// `agents_directory`, for the person. The current session can be given a
// handle here, the name other agents (and watches) reach it by.
import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { useSessions, useSetThreadHandle, useSetThreadOnDuty, type SessionEntry } from "@/core/projects";
import { useFrame } from "@/core/frame";
import { useViewport } from "@/core/viewport";
import { useChatMaybe } from "@/ui/chat/ChatProvider";
import { copyText } from "@/ui/lib/clipboard";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

const s = t.directory;

function stateVariant(state: SessionEntry["state"]) {
  if (state === "running") return "default";
  if (state === "waiting") return "destructive";
  if (state === "idle") return "secondary";
  return "outline";
}

// the duty switch: whether other agents may wake this session. A handle or
// an active goal is a duty of its own, so the switch stays on for those.
function DutySwitch({ row, onChange }: { row: SessionEntry; onChange: (onDuty: boolean) => void }) {
  const implied = !!row.handle || row.goal?.status === "active";
  return (
    <label className="text-muted-foreground flex shrink-0 flex-col items-center justify-center gap-1 px-3 text-[11px]" title={implied ? s.onDutyImplied : undefined}>
      <Switch checked={row.onDuty} disabled={implied} onCheckedChange={onChange} aria-label={s.onDuty} />
      <span aria-hidden>{s.onDuty}</span>
    </label>
  );
}

export function SessionDirectory({ projectId, slug }: { projectId: string; slug: string }) {
  useTranslation();
  const { threadId } = useParams();
  const navigate = useNavigate();
  const chat = useChatMaybe();
  const frame = useFrame();
  const viewport = useViewport();
  const [scope, setScope] = useState<"project" | "all">("project");
  const [search, setSearch] = useState("");
  const sessions = useSessions(projectId);
  const allSessions = useSessions(scope === "all" ? projectId : undefined, "all");
  const listing = scope === "all" ? allSessions : sessions;
  const candidates = scope === "all"
    ? listing.data?.filter((row) => row.projectId !== projectId && row.onDuty && row.state !== "unrecoverable" && row.state !== "archived")
    : listing.data;
  const rows = candidates?.filter((row) =>
    [row.address, row.title, row.preview, row.goal?.objective].some((text) => text?.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase())),
  );
  const setHandle = useSetThreadHandle(projectId);
  const setOnDuty = useSetThreadOnDuty(projectId);
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

  const fullAddress = (row: SessionEntry) => row.projectSlug ? row.address : `${slug}:${row.address}`;
  const handoff = (row: SessionEntry) => {
    if (!chat) return;
    const composer = chat.runtime.thread.composer;
    composer.setText(`${s.handoffDraft(fullAddress(row))}\n\n${composer.getState().text}`);
    if (viewport !== "desktop") frame.close();
  };

  return (
    <div className="flex flex-col gap-2" data-testid="session-directory">
      <div className="flex flex-wrap gap-1">
        <Button size="sm" variant={scope === "project" ? "secondary" : "ghost"} aria-pressed={scope === "project"} onClick={() => setScope("project")}>{s.title}</Button>
        <Button size="sm" variant={scope === "all" ? "secondary" : "ghost"} aria-pressed={scope === "all"} onClick={() => setScope("all")}>{s.otherProjects}</Button>
      </div>
      <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder={s.search} aria-label={s.search} className="h-8" />
      {listing.isPending ? <Skeleton className="h-12 w-full" /> : null}
      {listing.isError ? <p role="alert" className="text-destructive text-xs">{listing.error.message}</p> : null}
      {candidates?.length === 0 ? <p className="text-muted-foreground text-xs">{scope === "all" ? s.otherEmpty : s.empty}</p> : null}
      {candidates && candidates.length > 0 && rows?.length === 0 ? <p className="text-muted-foreground text-xs">{s.noMatches}</p> : null}
      {rows && rows.length > 0 ? (
        <ul className="divide-y rounded-md border">
          {rows.map((row) => (
            <li key={row.threadId} data-testid="session-row" className="flex flex-col">
              <div className="flex items-stretch">
              <button
                type="button"
                className="hover:bg-accent/40 flex min-w-0 flex-1 flex-col gap-0.5 px-3 py-2 text-left"
                aria-current={row.threadId === threadId ? "true" : undefined}
                onClick={() => navigate(`/p/${row.projectSlug || slug}/t/${row.threadId}`)}
              >
                <span className="flex items-center gap-2">
                  <code className="min-w-0 break-all text-xs">{row.projectSlug ? row.address : row.handle ? `@${row.handle}` : row.address}</code>
                  {row.handle?.startsWith("watch-") ? <span title={s.watchSession}>⏰</span> : null}
                  <Badge variant={stateVariant(row.state)} className="ml-auto shrink-0">{s.states[row.state]}</Badge>
                </span>
                <span className="text-muted-foreground truncate text-xs">{row.title ?? row.preview ?? ""}</span>
                {row.goal ? <span className="text-muted-foreground truncate text-xs">{s.goal}: {row.goal.objective}</span> : null}
                {row.team.length > 0 ? <span className="text-muted-foreground truncate text-xs">{s.team}: {row.team.join(", ")}</span> : null}
              </button>
              {!row.projectSlug ? <DutySwitch row={row} onChange={(onDuty) => setOnDuty.mutateAsync({ threadId: row.threadId, onDuty }).catch((e: Error) => toast.error(e.message))} /> : null}
              </div>
              <div className="flex flex-wrap gap-1 px-3 pb-2">
                <Button size="sm" variant="ghost" className="h-7 px-2 text-xs" onClick={() => void copyText(fullAddress(row)).then(() => toast.success(s.addressCopied)).catch((e: Error) => toast.error(e.message))}>{s.copyAddress}</Button>
                {row.onDuty && row.threadId !== threadId && chat ? <Button size="sm" variant="outline" className="h-7 px-2 text-xs" disabled={!!chat.disabledReason} onClick={() => handoff(row)}>{s.handoff}</Button> : null}
              </div>
            </li>
          ))}
        </ul>
      ) : null}
      <p className="text-muted-foreground text-xs">{s.handoffHint}</p>
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
