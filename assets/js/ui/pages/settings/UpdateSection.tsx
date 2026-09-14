// Settings → 版本与更新: the running version, the latest release on GitHub
// (checked on request, and every few hours by the server), the upgrade
// button with its stages through the restart, and the GitHub token that
// lifts the API's anonymous rate limit.
import { ArrowUpCircle, ExternalLink, Loader2, RefreshCw } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { relativeTime } from "@/core/format";
import { inProgress, useUpgradeActions, useUpgradeStatus } from "@/core/upgrade";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.updatePage;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function UpdateSection() {
  const status = useUpgradeStatus();
  if (status.isPending) return <Skeleton className="h-24 w-full" />;
  if (status.isError && !status.data) return <p className="text-destructive text-sm">{status.error.message}</p>;
  const st = status.data!;
  return (
    <div className="flex flex-col gap-8" data-testid="section-update">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <Version />
      <Token hasToken={st.hasGithubToken} />
    </div>
  );
}

function Version() {
  const status = useUpgradeStatus();
  const actions = useUpgradeActions();
  const [confirm, setConfirm] = useState(false);
  const st = status.data!;
  const busy = inProgress(st.stage);
  const canUpgrade = st.installed && st.available && st.latest && !busy;
  return (
    <section className="flex flex-col gap-3 rounded-lg border p-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="font-medium">{s.version(st.current)}</p>
          <p className="text-muted-foreground mt-1 text-xs">
            {st.error ? (
              <span className="text-destructive">{st.error}</span>
            ) : st.latest ? (
              <>
                {st.available ? s.latest(st.latest) : s.upToDate}
                {st.notesUrl ? (
                  <>
                    {" · "}
                    <a href={st.notesUrl} target="_blank" rel="noreferrer" className="inline-flex items-center gap-0.5 underline">
                      {s.notes} <ExternalLink className="size-3" />
                    </a>
                  </>
                ) : null}
                {st.checkedAt ? ` · ${s.checkedAt(relativeTime(st.checkedAt))}` : null}
              </>
            ) : (
              s.neverChecked
            )}
          </p>
        </div>
        <Button variant="outline" size="sm" disabled={actions.check.isPending || busy} onClick={() => actions.check.mutate(undefined, { onError: fail })}>
          <RefreshCw className={`size-4 ${actions.check.isPending ? "animate-spin" : ""}`} /> {actions.check.isPending ? s.checking : s.check}
        </Button>
      </div>
      {!st.installed ? <p className="text-muted-foreground text-xs">{s.notInstalled}</p> : null}
      {busy ? (
        <p className="flex items-center gap-2 text-sm" role="status">
          <Loader2 className="size-4 animate-spin" /> {s.stages[st.stage]}
        </p>
      ) : st.stage === "installed" ? (
        <p className="text-warning text-sm" role="status">
          {s.installedManual}
          {st.message ? `：${st.message}` : null}
        </p>
      ) : st.stage === "failed" ? (
        <p className="text-destructive text-sm" role="status">
          {s.failed}
          {st.message}
        </p>
      ) : null}
      {canUpgrade ? (
        <div>
          <Button size="sm" onClick={() => setConfirm(true)}>
            <ArrowUpCircle className="size-4" /> {s.upgrade(st.latest!)}
          </Button>
        </div>
      ) : null}
      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.confirmTitle(st.current, st.latest ?? "")}</AlertDialogTitle>
            <AlertDialogDescription>{s.confirmHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => actions.apply.mutate(undefined, { onError: fail })}>{s.confirm}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}

function Token({ hasToken }: { hasToken: boolean }) {
  const actions = useUpgradeActions();
  const [draft, setDraft] = useState("");
  const save = (token: string | null) =>
    actions.setToken.mutate(token, {
      onSuccess: () => {
        setDraft("");
        toast.success(token ? s.tokenSaved : s.tokenCleared);
      },
      onError: fail,
    });
  return (
    <section className="flex flex-col gap-3 rounded-lg border p-3">
      <div className="flex items-center gap-2">
        <h2 className="text-base font-medium">{s.token}</h2>
        <Badge variant={hasToken ? "default" : "outline"}>{hasToken ? s.tokenSet : s.tokenUnset}</Badge>
      </div>
      <p className="text-muted-foreground text-xs">{s.tokenHint}</p>
      <form
        className="flex flex-wrap gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          if (draft.trim()) save(draft.trim());
        }}
      >
        <Label htmlFor="github-token" className="sr-only">
          {s.token}
        </Label>
        <Input id="github-token" type="password" autoComplete="off" placeholder="ghp_…" value={draft} onChange={(e) => setDraft(e.target.value)} className="min-w-0 flex-1 font-mono" />
        <Button type="submit" size="sm" variant="outline" disabled={!draft.trim() || actions.setToken.isPending}>
          {s.saveToken}
        </Button>
        {hasToken ? (
          <Button type="button" size="sm" variant="ghost" disabled={actions.setToken.isPending} onClick={() => save(null)}>
            {s.clearToken}
          </Button>
        ) : null}
      </form>
    </section>
  );
}
