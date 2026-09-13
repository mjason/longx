// GitHub Desktop's git, in a tool window: a branch button and a sync button
// on top, then Changes (files with their status, a checkbox each, the diff
// a tap away in the workbench, summary + description, commit / discard)
// and History (commits, one commit's message and files, undo of the last
// one). Branches live in a popover (switch — with a stash when the tree is
// dirty — create, delete); the remote in a dialog. Every action is the
// bundled git on the server; the tool only asks and shows.
import { ArrowDownUp, Check, ChevronDown, GitBranch, Loader2, Plus, RefreshCw, Trash2, Undo2 } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";
import { relativeTime, shortSha } from "@/core/format";
import { useFrame } from "@/core/frame";
import { useInitGit } from "@/core/projects";
import { useViewport } from "@/core/viewport";
import { useWorkbench } from "@/core/workbench";
import { useGitActions, useGitBranches, useGitChanges, useGitLog, useGitShow, type Change, type GitChanges } from "@/core/workspace";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { Alert, AlertDescription, AlertTitle } from "@/ui/components/ui/alert";
import { Button } from "@/ui/components/ui/button";
import { Checkbox } from "@/ui/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/ui/components/ui/dropdown-menu";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/ui/components/ui/tabs";
import { Textarea } from "@/ui/components/ui/textarea";
import { t } from "@/ui/strings";
import type { ProjectContext } from "../ProjectWindow";

const STATUS_COLOR: Record<string, string> = {
  modified: "text-warning",
  added: "text-success",
  untracked: "text-success",
  deleted: "text-destructive",
  renamed: "text-warning",
  copied: "text-success",
  unmerged: "text-destructive",
};

function StatusMark({ status }: { status: string }) {
  return (
    <span className={`w-10 shrink-0 text-right text-[10px] ${STATUS_COLOR[status] ?? "text-muted-foreground"}`} title={status}>
      {t.gitStatus[status] ?? status}
    </span>
  );
}

export function GitTool({ ctx }: { ctx: ProjectContext }) {
  const projectId = ctx.id;
  const changes = useGitChanges(projectId, { poll: true });
  const init = useInitGit(projectId);

  if (changes.isPending) return <Skeleton className="h-24 w-full" data-testid="git-tool" />;
  if (changes.isError) return <p className="text-destructive text-sm" data-testid="git-tool">{changes.error.message}</p>;

  if (!changes.data.repository) {
    return (
      <div className="flex flex-col gap-3 text-sm" data-testid="git-tool" role="alert">
        <div className="font-medium">{t.noGit}</div>
        <p className="text-muted-foreground">{t.noGitHint}</p>
        <Button size="sm" className="self-start" onClick={() => init.mutate(undefined, { onError: (e) => toast.error(e.message) })} disabled={init.isPending}>
          {init.isPending ? t.initializing : t.initGit}
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3 text-sm" data-testid="git-tool">
      <div className="flex items-center gap-2">
        <BranchButton projectId={projectId} repo={changes.data} />
        <SyncButton projectId={projectId} repo={changes.data} />
      </div>
      <Tabs defaultValue="changes">
        <TabsList className="w-full">
          <TabsTrigger value="changes" className="flex-1">
            {t.gitChanges}
            {changes.data.changes.length ? <span className="text-muted-foreground ml-1 text-xs">{changes.data.changes.length}</span> : null}
          </TabsTrigger>
          <TabsTrigger value="history" className="flex-1">
            {t.gitHistory}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="changes">
          <ChangesView projectId={projectId} repo={changes.data} />
        </TabsContent>
        <TabsContent value="history">
          <HistoryView projectId={projectId} />
        </TabsContent>
      </Tabs>
    </div>
  );
}

// ---- branches ----------------------------------------------------------------

function BranchButton({ projectId, repo }: { projectId: string; repo: GitChanges }) {
  const [open, setOpen] = useState(false);
  const branches = useGitBranches(projectId, open);
  const actions = useGitActions(projectId);
  const [filter, setFilter] = useState("");
  const [newName, setNewName] = useState("");
  const [switching, setSwitching] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);
  const dirty = repo.changes.length > 0;
  const current = repo.branch ?? t.detachedHead;

  const doSwitch = (name: string, stash: boolean) => {
    setSwitching(null);
    setOpen(false);
    actions.switchBranch.mutate({ name, stash }, { onError: (e) => toast.error(e.message) });
  };

  return (
    <>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button variant="secondary" size="sm" className="min-w-0 flex-1 justify-start gap-1.5" aria-label={t.currentBranch(current)} title={t.currentBranch(current)}>
            <GitBranch className="size-3.5 shrink-0" />
            <span className="truncate font-mono">{current}</span>
            <ChevronDown className="ml-auto size-3.5 shrink-0 opacity-60" />
          </Button>
        </PopoverTrigger>
        <PopoverContent align="start" className="w-72 p-2" aria-label={t.branches} role="dialog">
          <Input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder={t.filterBranches} className="mb-2 h-8" aria-label={t.filterBranches} />
          <ul className="max-h-56 overflow-y-auto" role="list">
            {(branches.data?.branches ?? [])
              .filter((b) => b.name.includes(filter))
              .map((b) => (
                <li key={b.name} className="group flex items-center gap-1">
                  <button
                    type="button"
                    className="hover:bg-accent flex h-8 min-w-0 flex-1 items-center gap-2 rounded-md px-2 text-left font-mono text-xs disabled:opacity-100"
                    disabled={b.current}
                    onClick={() => (dirty ? setSwitching(b.name) : doSwitch(b.name, false))}
                  >
                    <Check className={`size-3.5 shrink-0 ${b.current ? "" : "invisible"}`} />
                    <span className="truncate">{b.name}</span>
                    {b.upstream ? <span className="text-muted-foreground ml-auto truncate text-[10px]">{b.upstream}</span> : null}
                  </button>
                  {!b.current ? (
                    <button type="button" aria-label={t.deleteBranch(b.name)} className="text-muted-foreground hover:text-destructive rounded p-1 opacity-0 group-hover:opacity-100 focus:opacity-100 max-lg:opacity-100" onClick={() => setDeleting(b.name)}>
                      <Trash2 className="size-3.5" />
                    </button>
                  ) : null}
                </li>
              ))}
            {branches.isPending ? <li><Skeleton className="h-6 w-2/3" /></li> : null}
          </ul>
          <form
            className="mt-2 flex items-center gap-1 border-t pt-2"
            onSubmit={(e) => {
              e.preventDefault();
              const name = newName.trim();
              if (!name) return;
              actions.createBranch.mutate(name, {
                onSuccess: () => {
                  setNewName("");
                  setOpen(false);
                },
                onError: (err) => toast.error(err.message),
              });
            }}
          >
            <Input value={newName} onChange={(e) => setNewName(e.target.value)} placeholder={t.newBranchName} aria-label={t.newBranchName} className="h-8 font-mono text-xs" autoCapitalize="none" spellCheck={false} />
            <Button type="submit" size="sm" variant="secondary" className="h-8" disabled={!newName.trim() || actions.createBranch.isPending}>
              <Plus /> {t.createBranch}
            </Button>
          </form>
          {branches.data?.stashes.length ? (
            <div className="text-muted-foreground mt-2 flex items-center justify-between border-t pt-2 text-xs">
              <span>{t.stashes(branches.data.stashes.length)}</span>
              <Button variant="ghost" size="sm" className="h-7 px-2" onClick={() => actions.stashPop.mutate(undefined, { onError: (e) => toast.error(e.message) })}>
                {t.popStash}
              </Button>
            </div>
          ) : null}
        </PopoverContent>
      </Popover>

      <AlertDialog open={switching !== null} onOpenChange={(o) => (o ? null : setSwitching(null))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.switchDirtyTitle(switching ?? "")}</AlertDialogTitle>
            <AlertDialogDescription>{t.switchDirtyHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <Button variant="secondary" onClick={() => switching && doSwitch(switching, false)}>
              {t.switchWithChanges}
            </Button>
            <AlertDialogAction onClick={() => switching && doSwitch(switching, true)}>{t.stashAndSwitch}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog open={deleting !== null} onOpenChange={(o) => (o ? null : setDeleting(null))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.deleteBranchTitle(deleting ?? "")}</AlertDialogTitle>
            <AlertDialogDescription>{t.deleteBranchHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => {
                if (!deleting) return;
                actions.deleteBranch.mutate({ name: deleting, force: true }, { onError: (e) => toast.error(e.message) });
                setDeleting(null);
              }}
            >
              {t.deleteEntry}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

// ---- sync ----------------------------------------------------------------------

function SyncButton({ projectId, repo }: { projectId: string; repo: GitChanges }) {
  const actions = useGitActions(projectId);
  const [remoteDialog, setRemoteDialog] = useState(false);
  const [url, setUrl] = useState(repo.remotes[0]?.url ?? "");
  const busy = actions.fetch.isPending || actions.pull.isPending || actions.push.isPending;
  const run = (m: { mutate: (v: undefined, o: { onSuccess: () => void; onError: (e: Error) => void }) => void }) =>
    m.mutate(undefined, { onSuccess: () => toast.success(t.synced), onError: (e) => toast.error(e.message) });

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="secondary" size="sm" className="gap-1.5" aria-label={t.sync} title={t.sync} disabled={busy}>
            {busy ? <Loader2 className="size-3.5 animate-spin" /> : <ArrowDownUp className="size-3.5" />}
            {repo.behind ? <span className="font-mono text-xs">↓{repo.behind}</span> : null}
            {repo.ahead ? <span className="font-mono text-xs">↑{repo.ahead}</span> : null}
            {!repo.behind && !repo.ahead ? <span className="text-xs">{t.sync}</span> : null}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          {repo.remotes.length ? (
            <>
              <DropdownMenuItem onSelect={() => run(actions.fetch)}>
                <RefreshCw /> {t.fetch}
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={() => run(actions.pull)}>{t.pull(repo.behind ?? 0)}</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => run(actions.push)}>{t.push(repo.ahead ?? 0)}</DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => setRemoteDialog(true)}>{t.editRemote}</DropdownMenuItem>
            </>
          ) : (
            <>
              <DropdownMenuItem disabled>{t.noRemote}</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => setRemoteDialog(true)}>{t.addRemote}</DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
      <Dialog open={remoteDialog} onOpenChange={setRemoteDialog}>
        <DialogContent aria-label={t.remoteTitle}>
          <DialogHeader>
            <DialogTitle>{t.remoteTitle}</DialogTitle>
            <DialogDescription>{t.remoteHint}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-2">
            <Label htmlFor="remote-url">{t.remoteUrl}</Label>
            <Input id="remote-url" value={url} onChange={(e) => setUrl(e.target.value)} className="font-mono" autoCapitalize="none" spellCheck={false} />
          </div>
          <DialogFooter>
            <Button variant="secondary" onClick={() => setRemoteDialog(false)}>
              {t.cancel}
            </Button>
            <Button
              disabled={!url.trim() || actions.setRemote.isPending}
              onClick={() =>
                actions.setRemote.mutate({ name: "origin", url: url.trim() }, { onSuccess: () => setRemoteDialog(false), onError: (e) => toast.error(e.message) })
              }
            >
              {t.save}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

// ---- changes -------------------------------------------------------------------

function ChangesView({ projectId, repo }: { projectId: string; repo: GitChanges }) {
  const actions = useGitActions(projectId);
  const workbench = useWorkbench(projectId);
  const frame = useFrame();
  const viewport = useViewport();
  // unchecked paths, so a new change starts checked (GitHub Desktop's default)
  const [unchecked, setUnchecked] = useState<Set<string>>(() => new Set());
  const [summary, setSummary] = useState("");
  const [description, setDescription] = useState("");
  const [discarding, setDiscarding] = useState(false);
  const selected = useMemo(() => repo.changes.filter((c) => !unchecked.has(c.path)).map((c) => c.path), [repo.changes, unchecked]);
  const allChecked = selected.length === repo.changes.length;

  const openDiff = (change: Change) => {
    workbench.open({ kind: "diff", path: change.path, sha: null });
    if (viewport !== "desktop") frame.close();
  };

  const commit = () => {
    const message = description.trim() ? `${summary.trim()}\n\n${description.trim()}` : summary.trim();
    actions.commit.mutate(
      { paths: selected, message },
      {
        onSuccess: () => {
          setSummary("");
          setDescription("");
          toast.success(t.committed);
        },
        onError: (e) => toast.error(e.message),
      },
    );
  };

  if (repo.changes.length === 0 && !repo.merging) return <p className="text-muted-foreground py-2 text-sm">{t.noChanges}</p>;

  return (
    <div className="flex flex-col gap-3">
      {repo.merging ? <MergeBanner projectId={projectId} /> : null}
      <label className="text-muted-foreground flex items-center gap-2 px-1 text-xs">
        <Checkbox checked={allChecked} onCheckedChange={(v) => setUnchecked(v === true ? new Set() : new Set(repo.changes.map((c) => c.path)))} aria-label={t.selectAll} />
        {t.changedFilesCount(repo.changes.length)}
      </label>
      <ul className="rounded-md border" data-testid="git-changes">
        {repo.changes.map((c) => (
          <li key={c.path} className="hover:bg-accent/40 flex items-center gap-2 px-2">
            <Checkbox
              checked={!unchecked.has(c.path)}
              aria-label={c.path}
              onCheckedChange={(v) =>
                setUnchecked((prev) => {
                  const next = new Set(prev);
                  if (v === true) next.delete(c.path);
                  else next.add(c.path);
                  return next;
                })
              }
            />
            <button type="button" className="touch-target flex min-w-0 flex-1 items-center gap-2 py-1 text-left" onClick={() => openDiff(c)}>
              <span className="truncate font-mono text-xs">{c.path}</span>
              <StatusMark status={c.status} />
            </button>
          </li>
        ))}
      </ul>
      <div className="flex flex-col gap-2">
        <Label htmlFor="commit-summary" className="sr-only">
          {t.summary}
        </Label>
        <Input id="commit-summary" aria-label={t.summary} value={summary} onChange={(e) => setSummary(e.target.value)} placeholder={t.summaryPlaceholder} className="h-9" />
        <Label htmlFor="commit-description" className="sr-only">
          {t.descriptionOptional}
        </Label>
        <Textarea id="commit-description" aria-label={t.descriptionOptional} value={description} onChange={(e) => setDescription(e.target.value)} placeholder={t.descriptionOptional} rows={2} className="min-h-0 text-sm" />
        <div className="flex flex-wrap gap-2">
          <Button size="sm" className="flex-1" disabled={!summary.trim() || selected.length === 0 || actions.commit.isPending} onClick={commit}>
            {actions.commit.isPending ? t.committing : t.commitTo(repo.branch ?? "HEAD")}
          </Button>
          <Button size="sm" variant="ghost" className="text-destructive" disabled={selected.length === 0} onClick={() => setDiscarding(true)}>
            {t.discardSelected}
          </Button>
        </div>
      </div>
      <AlertDialog open={discarding} onOpenChange={setDiscarding}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.discardTitle(selected.length)}</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div>
                <p>{t.discardHint}</p>
                <ul className="mt-2 max-h-32 overflow-y-auto font-mono text-xs">
                  {selected.map((p) => (
                    <li key={p}>{p}</li>
                  ))}
                </ul>
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => {
                actions.discard.mutate(selected, { onError: (e) => toast.error(e.message) });
                setDiscarding(false);
              }}
            >
              {t.discard}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function MergeBanner({ projectId }: { projectId: string }) {
  const actions = useGitActions(projectId);
  const [aborting, setAborting] = useState(false);
  return (
    <Alert>
      <AlertTitle>{t.merging}</AlertTitle>
      <AlertDescription>
        <p>{t.mergingHint}</p>
        <Button variant="secondary" size="sm" className="mt-2" onClick={() => setAborting(true)}>
          {t.abortMerge}
        </Button>
      </AlertDescription>
      <AlertDialog open={aborting} onOpenChange={setAborting}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.abortMergeTitle}</AlertDialogTitle>
            <AlertDialogDescription>{t.abortMergeHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => {
                actions.abortMerge.mutate(undefined, { onError: (e) => toast.error(e.message) });
                setAborting(false);
              }}
            >
              {t.abortMerge}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Alert>
  );
}

// ---- history -------------------------------------------------------------------

const PAGE = 30;

function HistoryView({ projectId }: { projectId: string }) {
  const [pages, setPages] = useState(1);
  const [selected, setSelected] = useState<string | null>(null);
  const [undoing, setUndoing] = useState(false);
  const actions = useGitActions(projectId);
  const log = useGitLog(projectId, PAGE * pages, 0);
  const commit = useGitShow(projectId, selected);
  const workbench = useWorkbench(projectId);
  const frame = useFrame();
  const viewport = useViewport();

  if (log.isPending) return <Skeleton className="h-24 w-full" />;
  if (log.isError) return <p className="text-destructive text-sm">{log.error.message}</p>;
  if (log.data.length === 0) return <p className="text-muted-foreground py-2 text-sm">{t.noCommits}</p>;

  return (
    <div className="flex flex-col gap-2">
      <Button variant="ghost" size="sm" className="self-start" onClick={() => setUndoing(true)}>
        <Undo2 /> {t.undoCommit}
      </Button>
      <ul className="rounded-md border" data-testid="git-log">
        {log.data.map((entry) => (
          <li key={entry.sha}>
            <button
              type="button"
              className={`touch-target hover:bg-accent/40 flex w-full flex-col items-start px-2 py-1 text-left ${entry.sha === selected ? "bg-accent/60" : ""}`}
              onClick={() => setSelected(entry.sha === selected ? null : entry.sha)}
            >
              <span className="w-full truncate text-sm">{entry.subject}</span>
              <span className="text-muted-foreground flex gap-2 text-xs">
                <span className="font-mono">{shortSha(entry.sha)}</span>
                <span>{entry.author}</span>
                <span>{relativeTime(entry.at)}</span>
              </span>
            </button>
            {entry.sha === selected ? (
              <div className="bg-muted/40 border-t px-2 py-2 text-xs" data-testid="git-commit">
                {commit.isPending ? (
                  <Skeleton className="h-10 w-full" />
                ) : commit.isError ? (
                  <p className="text-destructive">{commit.error.message}</p>
                ) : (
                  <>
                    {commit.data.body ? <p className="mb-2 whitespace-pre-wrap">{commit.data.body}</p> : null}
                    <p className="text-muted-foreground mb-1">{t.commitFiles(commit.data.files.length)}</p>
                    <ul>
                      {commit.data.files.map((f) => (
                        <li key={f.path}>
                          <button
                            type="button"
                            className="touch-target hover:bg-accent/40 flex w-full items-center gap-2 rounded px-1 py-0.5 text-left"
                            onClick={() => {
                              workbench.open({ kind: "diff", path: f.path, sha: entry.sha });
                              if (viewport !== "desktop") frame.close();
                            }}
                          >
                            <span className="truncate font-mono">{f.path}</span>
                            <StatusMark status={f.status} />
                          </button>
                        </li>
                      ))}
                    </ul>
                  </>
                )}
              </div>
            ) : null}
          </li>
        ))}
      </ul>
      {log.data.length >= PAGE * pages ? (
        <Button variant="ghost" size="sm" onClick={() => setPages((p) => p + 1)}>
          {t.loadMoreCommits}
        </Button>
      ) : null}
      <AlertDialog open={undoing} onOpenChange={setUndoing}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.undoCommitTitle}</AlertDialogTitle>
            <AlertDialogDescription>{t.undoCommitHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                actions.undoCommit.mutate(undefined, { onError: (e) => toast.error(e.message) });
                setUndoing(false);
              }}
            >
              {t.undoCommitAction}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
