// IDEA's / VS Code's project tree: folders first, children loaded when a
// folder opens, git status coloured on files and rolled up onto their
// folders, a row menu for new / rename / delete, and a filter over codex's
// fuzzy file index. A file opens as a tab in the workbench; on a phone the
// tree is a sheet, so the tap also closes it.
import { ChevronRight, File, FilePlus2, Folder, FolderOpen, FolderPlus, ListCollapse, MoreHorizontal, RefreshCw } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";
import { useQueryClient } from "@tanstack/react-query";
import { useFrame } from "@/core/frame";
import { useViewport } from "@/core/viewport";
import { useWorkbench } from "@/core/workbench";
import { searchFiles } from "@/ash_rpc";
import { unwrap } from "@/core/projects";
import { useQuery } from "@tanstack/react-query";
import { useCreateEntry, useDeleteEntry, useFiles, useGitChanges, useRenameEntry, wsKeys, type FileEntry } from "@/core/workspace";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { Button } from "@/ui/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/ui/components/ui/dropdown-menu";
import { Input } from "@/ui/components/ui/input";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";
import type { ProjectContext } from "../ProjectWindow";

type GitStatus = Map<string, string>;
type Ignored = string[];

/** `.gitignore` hides it: the path, or a directory above it, is in the ignored list. */
function ignoredEntry(ignored: Ignored, entry: FileEntry): boolean {
  const path = entry.kind === "dir" ? entry.path + "/" : entry.path;
  return ignored.some((i) => path === i || (i.endsWith("/") && path.startsWith(i)));
}

const GIT_COLOR: Record<string, string> = {
  modified: "text-warning",
  added: "text-success",
  untracked: "text-success",
  deleted: "text-destructive line-through",
  renamed: "text-warning",
  copied: "text-success",
  unmerged: "text-destructive",
};

/** The status of a path, or of anything under it (a folder shows its children's). */
function statusOf(git: GitStatus, entry: FileEntry): string | undefined {
  if (entry.kind === "file") return git.get(entry.path);
  for (const [path, status] of git) if (path.startsWith(entry.path + "/")) return status;
  return undefined;
}

type Editing = { kind: "new-file" | "new-folder"; parent: string } | { kind: "rename"; entry: FileEntry } | null;

export function FilesTool({ ctx }: { ctx: ProjectContext }) {
  const projectId = ctx.id;
  const client = useQueryClient();
  const changes = useGitChanges(projectId);
  const git = useMemo<GitStatus>(() => new Map((changes.data?.changes ?? []).map((c) => [c.path, c.status])), [changes.data]);
  const ignored = changes.data?.ignored ?? [];
  const [filter, setFilter] = useState("");
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const [editing, setEditing] = useState<Editing>(null);
  const [deleting, setDeleting] = useState<FileEntry | null>(null);
  const [version, setVersion] = useState(0);

  const toggle = (path: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });

  return (
    <div className="flex flex-col gap-2" data-testid="files-tool">
      <div className="flex items-center gap-1">
        <Button variant="ghost" size="icon" className="size-8" aria-label={t.newFile} title={t.newFile} onClick={() => setEditing({ kind: "new-file", parent: "" })}>
          <FilePlus2 />
        </Button>
        <Button variant="ghost" size="icon" className="size-8" aria-label={t.newFolder} title={t.newFolder} onClick={() => setEditing({ kind: "new-folder", parent: "" })}>
          <FolderPlus />
        </Button>
        <Button variant="ghost" size="icon" className="size-8" aria-label={t.collapseAll} title={t.collapseAll} onClick={() => setExpanded(new Set())}>
          <ListCollapse />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="size-8"
          aria-label={t.refresh}
          title={t.refresh}
          onClick={() => {
            void client.invalidateQueries({ queryKey: wsKeys.filesOf(projectId) });
            void changes.refetch();
            setVersion((v) => v + 1);
          }}
        >
          <RefreshCw />
        </Button>
      </div>
      <Input type="search" role="searchbox" aria-label={t.filterFiles} placeholder={t.filterFiles} value={filter} onChange={(e) => setFilter(e.target.value)} className="h-8 text-sm" autoCapitalize="none" spellCheck={false} />
      {filter.trim() ? (
        <FilterResults projectId={projectId} query={filter.trim()} git={git} />
      ) : (
        <div role="tree" aria-label={t.tools["files"]} className="text-sm">
          {editing && editing.kind !== "rename" && editing.parent === "" ? <NameRow depth={0} projectId={projectId} editing={editing} onDone={() => setEditing(null)} /> : null}
          <Level key={version} projectId={projectId} path="" depth={0} git={git} ignored={ignored} expanded={expanded} onToggle={toggle} editing={editing} setEditing={setEditing} onDelete={setDeleting} />
        </div>
      )}
      <DeleteDialog projectId={projectId} entry={deleting} onClose={() => setDeleting(null)} />
    </div>
  );
}

/** VS Code's quick open, inside the tool: codex's fuzzy file index, a tap opens. */
function FilterResults({ projectId, query, git }: { projectId: string; query: string; git: GitStatus }) {
  const workbench = useWorkbench(projectId);
  const frame = useFrame();
  const viewport = useViewport();
  const results = useQuery({
    queryKey: ["file-search", projectId, query],
    queryFn: async () => unwrap(await searchFiles({ fields: ["path", "fileName", "matchType"], input: { id: projectId, query } })),
  });
  if (results.isPending) return <Skeleton className="h-5 w-1/2" />;
  if (results.isError) return <p className="text-destructive text-xs">{results.error.message}</p>;
  if (results.data.length === 0) return <p className="text-muted-foreground text-xs">{t.noFilesMatch}</p>;
  return (
    <ul className="text-sm">
      {results.data.map((hit) => (
        <li key={hit.path}>
          <button
            type="button"
            className={`touch-target hover:bg-sidebar-accent/60 flex w-full items-center gap-1.5 rounded-md px-1 py-1 text-left ${GIT_COLOR[git.get(hit.path) ?? ""] ?? ""}`}
            onClick={() => {
              if (hit.matchType === "directory") return;
              workbench.open({ kind: "file", path: hit.path });
              if (viewport !== "desktop") frame.close();
            }}
          >
            {hit.matchType === "directory" ? <Folder className="text-muted-foreground size-4 shrink-0" /> : <File className="text-muted-foreground size-4 shrink-0" />}
            <span className="truncate font-mono text-xs">
              {hit.fileName}
              {hit.path.length > hit.fileName.length ? <span className="text-muted-foreground"> {hit.path.slice(0, -hit.fileName.length - 1)}</span> : null}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function Level(props: {
  projectId: string;
  path: string;
  depth: number;
  git: GitStatus;
  ignored: Ignored;
  expanded: Set<string>;
  onToggle: (path: string) => void;
  editing: Editing;
  setEditing: (e: Editing) => void;
  onDelete: (entry: FileEntry) => void;
}) {
  const { projectId, path, depth, git, ignored, expanded, onToggle, editing, setEditing, onDelete } = props;
  const files = useFiles(projectId, path);
  if (files.isPending) return <Skeleton className="my-1 ml-4 h-5 w-1/2" />;
  if (files.isError) return <p className="text-destructive px-2 py-1 text-xs">{t.filesLoadFailed(files.error.message)}</p>;
  if (files.data.length === 0 && path !== "") return <p className="text-muted-foreground px-2 py-1 text-xs" style={{ paddingLeft: depth * 16 + 24 }}>{t.emptyFolder}</p>;

  return (
    <ul role="group">
      {files.data.map((entry) => {
        const open = entry.kind === "dir" && expanded.has(entry.path);
        return (
          <li key={entry.path}>
            {editing?.kind === "rename" && editing.entry.path === entry.path ? (
              <NameRow depth={depth} projectId={projectId} editing={editing} onDone={() => setEditing(null)} />
            ) : (
              <Row entry={entry} depth={depth} open={open} status={statusOf(git, entry)} ignored={ignoredEntry(ignored, entry)} projectId={projectId} onToggle={onToggle} setEditing={setEditing} onDelete={onDelete} />
            )}
            {open ? (
              <>
                {editing && editing.kind !== "rename" && editing.parent === entry.path ? <NameRow depth={depth + 1} projectId={projectId} editing={editing} onDone={() => setEditing(null)} /> : null}
                <Level {...props} path={entry.path} depth={depth + 1} />
              </>
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}

function Row({ entry, depth, open, status, ignored, projectId, onToggle, setEditing, onDelete }: { entry: FileEntry; depth: number; open: boolean; status: string | undefined; ignored: boolean; projectId: string; onToggle: (p: string) => void; setEditing: (e: Editing) => void; onDelete: (e: FileEntry) => void }) {
  const workbench = useWorkbench(projectId);
  const frame = useFrame();
  const viewport = useViewport();
  const activate = () => {
    if (entry.kind === "dir") return onToggle(entry.path);
    workbench.open({ kind: "file", path: entry.path });
    if (viewport !== "desktop") frame.close();
  };
  const Icon = entry.kind === "dir" ? (open ? FolderOpen : Folder) : File;
  return (
    <div className="group hover:bg-sidebar-accent/60 flex items-center rounded-md" style={{ paddingLeft: depth * 16 }}>
      <button type="button" role="treeitem" aria-expanded={entry.kind === "dir" ? open : undefined} aria-label={entry.name} data-git={status} data-ignored={ignored || undefined} className={`touch-target flex min-w-0 flex-1 items-center gap-1.5 py-1 pr-1 text-left ${status ? (GIT_COLOR[status] ?? "") : ignored ? "text-muted-foreground/60" : ""}`} onClick={activate}>
        <ChevronRight className={`text-muted-foreground size-3.5 shrink-0 transition-transform ${entry.kind === "dir" ? (open ? "rotate-90" : "") : "invisible"}`} />
        <Icon className="text-muted-foreground size-4 shrink-0" />
        <span className="truncate">{entry.name}</span>
      </button>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button type="button" aria-label={`${entry.name} 的操作`} className="text-muted-foreground hover:text-foreground touch-target flex items-center justify-center rounded p-1 opacity-0 group-hover:opacity-100 focus:opacity-100 data-[state=open]:opacity-100 max-lg:opacity-100">
            <MoreHorizontal className="size-4" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          {entry.kind === "dir" ? (
            <>
              <DropdownMenuItem onSelect={() => { onToggle(entry.path); if (!open) onToggle(entry.path); setEditing({ kind: "new-file", parent: entry.path }); }}>{t.newFile}</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => { if (!open) onToggle(entry.path); setEditing({ kind: "new-folder", parent: entry.path }); }}>{t.newFolder}</DropdownMenuItem>
            </>
          ) : null}
          <DropdownMenuItem onSelect={() => setEditing({ kind: "rename", entry })}>{t.renameEntry}</DropdownMenuItem>
          <DropdownMenuItem className="text-destructive" onSelect={() => onDelete(entry)}>{t.deleteEntry}</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}

/** The inline name field for a new entry or a rename; Enter confirms, Escape cancels. */
function NameRow({ depth, projectId, editing, onDone }: { depth: number; projectId: string; editing: NonNullable<Editing>; onDone: () => void }) {
  const create = useCreateEntry(projectId);
  const rename = useRenameEntry(projectId);
  const workbench = useWorkbench(projectId);
  const [name, setName] = useState(editing.kind === "rename" ? editing.entry.name : "");
  const submit = () => {
    const clean = name.trim();
    if (!clean) return onDone();
    if (editing.kind === "rename") {
      const parent = editing.entry.path.split("/").slice(0, -1).join("/");
      const to = parent ? `${parent}/${clean}` : clean;
      rename.mutate({ from: editing.entry.path, to }, { onSuccess: () => { workbench.renamePath(editing.entry.path, to); onDone(); }, onError: (e) => toast.error(e.message) });
    } else {
      const path = editing.parent ? `${editing.parent}/${clean}` : clean;
      create.mutate({ path, kind: editing.kind === "new-folder" ? "dir" : "file" }, {
        onSuccess: (made) => { if (made.kind === "file") workbench.open({ kind: "file", path: made.path }); onDone(); },
        onError: (e) => toast.error(e.message),
      });
    }
  };
  return (
    <form className="flex items-center gap-1 py-0.5" style={{ paddingLeft: depth * 16 + 20 }} onSubmit={(e) => { e.preventDefault(); submit(); }}>
      {editing.kind === "new-folder" ? <Folder className="text-muted-foreground size-4 shrink-0" /> : <File className="text-muted-foreground size-4 shrink-0" />}
      <Input aria-label={t.entryName} value={name} onChange={(e) => setName(e.target.value)} onBlur={() => (name.trim() ? submit() : onDone())} onKeyDown={(e) => e.key === "Escape" && onDone()} className="h-7 font-mono text-sm" autoFocus autoCapitalize="none" spellCheck={false} />
    </form>
  );
}

function DeleteDialog({ projectId, entry, onClose }: { projectId: string; entry: FileEntry | null; onClose: () => void }) {
  const del = useDeleteEntry(projectId);
  const workbench = useWorkbench(projectId);
  return (
    <AlertDialog open={entry !== null} onOpenChange={(open) => (open ? null : onClose())}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{entry ? t.deleteEntryTitle(entry.name) : ""}</AlertDialogTitle>
          <AlertDialogDescription>{entry?.kind === "dir" ? t.deleteFolderHint : t.deleteEntryHint}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
          <AlertDialogAction
            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            onClick={() => {
              if (!entry) return;
              del.mutate(entry.path, {
                onSuccess: () => {
                  workbench.close(`file:${entry.path}`);
                  onClose();
                },
                onError: (e) => toast.error(e.message),
              });
            }}
          >
            {t.deleteEntry}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
