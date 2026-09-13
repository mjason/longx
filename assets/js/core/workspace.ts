// The project's files (tree + editor) and its git (changes, history,
// branches, remote) as TanStack Query hooks over the generated RPC client.
// DOM-free. Every git mutation invalidates every git query and the file
// tree: what a commit, a switch or a pull changes on disk is exactly what
// those show.
import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import {
  createEntry,
  deleteEntry,
  gitBranches,
  gitChanges,
  gitCommit,
  gitCommitFileDiff,
  gitCreateBranch,
  gitDeleteBranch,
  gitDiscard,
  gitFetch,
  gitFileDiff,
  gitLog,
  gitPull,
  gitPush,
  gitSetRemote,
  gitShow,
  gitStashPop,
  gitSwitch,
  gitUndoCommit,
  listFiles,
  readFile,
  renameEntry,
  writeFile,
} from "@/ash_rpc";
import { unwrap } from "./projects";

export type FileEntry = { name: string; path: string; kind: "file" | "dir"; size: number };
export type FileContent = { path: string; content: string | null; size: number; binary: boolean; truncated: boolean };
export type Change = { path: string; status: string };
export type GitChanges = {
  repository: boolean;
  branch: string | null;
  head: string | null;
  changes: Change[];
  ahead: number | null;
  behind: number | null;
  remotes: { name: string; url: string }[];
  lfs: boolean;
};
export type LogEntry = { sha: string; subject: string; author: string; email: string; at: string };
export type Commit = LogEntry & { body: string; parents: string[]; files: Change[] };
export type Branch = { name: string; sha: string; current: boolean; upstream: string | null };
export type Branches = { current: string | null; branches: Branch[]; stashes: { index: number; message: string }[] };
export type FileDiff = { binary: boolean; diff: string };

export const wsKeys = {
  files: (id: string, path: string) => ["files", id, path] as const,
  filesOf: (id: string) => ["files", id] as const,
  file: (id: string, path: string) => ["file", id, path] as const,
  git: (id: string) => ["git", id] as const,
  changes: (id: string) => ["git", id, "changes"] as const,
  fileDiff: (id: string, path: string) => ["git", id, "diff", path] as const,
  log: (id: string, limit: number, skip: number) => ["git", id, "log", limit, skip] as const,
  show: (id: string, sha: string) => ["git", id, "show", sha] as const,
  commitDiff: (id: string, sha: string, path: string) => ["git", id, "commit", sha, path] as const,
  branches: (id: string) => ["git", id, "branches"] as const,
};

export const entryFields = ["name", "path", "kind", "size"] as const;

export function useFiles(projectId: string, path: string, enabled = true) {
  return useQuery({
    queryKey: wsKeys.files(projectId, path),
    enabled,
    queryFn: async () => unwrap(await listFiles({ fields: [...entryFields], input: { projectId, path } })) as FileEntry[],
  });
}

export function useFileContent(projectId: string, path: string | null) {
  return useQuery({
    queryKey: wsKeys.file(projectId, path ?? ""),
    enabled: path !== null,
    queryFn: async () =>
      unwrap(await readFile({ fields: ["path", "content", "size", "binary", "truncated"], input: { projectId, path: path! } })) as FileContent,
  });
}

function invalidateFiles(client: QueryClient, projectId: string) {
  void client.invalidateQueries({ queryKey: wsKeys.filesOf(projectId) });
  void client.invalidateQueries({ queryKey: wsKeys.changes(projectId) });
}

export function useSaveFile(projectId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async ({ path, content }: { path: string; content: string }) => unwrap(await writeFile({ input: { projectId, path, content } })),
    onSuccess: (_r, { path, content }) => {
      client.setQueryData(wsKeys.file(projectId, path), (prev: FileContent | undefined) =>
        prev ? { ...prev, content, size: new TextEncoder().encode(content).length } : prev,
      );
      invalidateFiles(client, projectId);
    },
  });
}

export function useCreateEntry(projectId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async ({ path, kind }: { path: string; kind: "file" | "dir" }) =>
      unwrap(await createEntry({ fields: [...entryFields], input: { projectId, path, kind } })) as FileEntry,
    onSuccess: () => invalidateFiles(client, projectId),
  });
}

export function useRenameEntry(projectId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async ({ from, to }: { from: string; to: string }) =>
      unwrap(await renameEntry({ fields: [...entryFields], input: { projectId, from, to } })) as FileEntry,
    onSuccess: () => invalidateFiles(client, projectId),
  });
}

export function useDeleteEntry(projectId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (path: string) => unwrap(await deleteEntry({ input: { projectId, path } })),
    onSuccess: () => invalidateFiles(client, projectId),
  });
}

// ---- git -------------------------------------------------------------------

export const changesFields = ["repository", "branch", "head", "changes", "ahead", "behind", "remotes", "lfs"] as const;

/** The changes view; polled while shown — the agent edits files without telling us. */
export function useGitChanges(projectId: string, opts: { poll?: boolean } = {}) {
  return useQuery({
    queryKey: wsKeys.changes(projectId),
    queryFn: async () => unwrap(await gitChanges({ fields: [...changesFields], input: { projectId } })) as GitChanges,
    refetchInterval: opts.poll ? 10_000 : false,
    refetchOnWindowFocus: true,
  });
}

export function useGitFileDiff(projectId: string, path: string | null) {
  return useQuery({
    queryKey: wsKeys.fileDiff(projectId, path ?? ""),
    enabled: path !== null,
    queryFn: async () => unwrap(await gitFileDiff({ fields: ["binary", "diff"], input: { projectId, path: path! } })) as FileDiff,
  });
}

export const logFields = ["sha", "subject", "author", "email", "at"] as const;

export function useGitLog(projectId: string, limit = 50, skip = 0, enabled = true) {
  return useQuery({
    queryKey: wsKeys.log(projectId, limit, skip),
    enabled,
    queryFn: async () => unwrap(await gitLog({ fields: [...logFields], input: { projectId, limit, skip } })) as LogEntry[],
  });
}

export function useGitShow(projectId: string, sha: string | null) {
  return useQuery({
    queryKey: wsKeys.show(projectId, sha ?? ""),
    enabled: sha !== null,
    queryFn: async () =>
      unwrap(await gitShow({ fields: [...logFields, "body", "parents", "files"], input: { projectId, sha: sha! } })) as Commit,
  });
}

export function useGitCommitFileDiff(projectId: string, sha: string | null, path: string | null) {
  return useQuery({
    queryKey: wsKeys.commitDiff(projectId, sha ?? "", path ?? ""),
    enabled: sha !== null && path !== null,
    queryFn: async () =>
      unwrap(await gitCommitFileDiff({ fields: ["binary", "diff"], input: { projectId, sha: sha!, path: path! } })) as FileDiff,
  });
}

export function useGitBranches(projectId: string, enabled = true) {
  return useQuery({
    queryKey: wsKeys.branches(projectId),
    enabled,
    queryFn: async () => unwrap(await gitBranches({ fields: ["current", "branches", "stashes"], input: { projectId } })) as Branches,
  });
}

function afterGit(client: QueryClient, projectId: string) {
  void client.invalidateQueries({ queryKey: wsKeys.git(projectId) });
  void client.invalidateQueries({ queryKey: wsKeys.filesOf(projectId) });
  void client.invalidateQueries({ queryKey: ["file", projectId] });
  void client.invalidateQueries({ queryKey: ["project", projectId, "git"] });
}

/** Every git action, each invalidating what it may have changed. */
export function useGitActions(projectId: string) {
  const client = useQueryClient();
  const done = () => afterGit(client, projectId);
  return {
    commit: useMutation({
      mutationFn: async ({ paths, message }: { paths: string[]; message: string }) =>
        unwrap(await gitCommit({ fields: ["sha"], input: { projectId, paths, message } })),
      onSuccess: done,
    }),
    discard: useMutation({ mutationFn: async (paths: string[]) => unwrap(await gitDiscard({ input: { projectId, paths } })), onSuccess: done }),
    undoCommit: useMutation({ mutationFn: async () => unwrap(await gitUndoCommit({ fields: ["sha"], input: { projectId } })), onSuccess: done }),
    createBranch: useMutation({ mutationFn: async (name: string) => unwrap(await gitCreateBranch({ input: { projectId, name } })), onSuccess: done }),
    switchBranch: useMutation({
      mutationFn: async ({ name, stash }: { name: string; stash?: boolean }) => unwrap(await gitSwitch({ input: { projectId, name, stash: stash ?? false } })),
      onSuccess: done,
    }),
    deleteBranch: useMutation({
      mutationFn: async ({ name, force }: { name: string; force?: boolean }) => unwrap(await gitDeleteBranch({ input: { projectId, name, force: force ?? false } })),
      onSuccess: done,
    }),
    stashPop: useMutation({ mutationFn: async () => unwrap(await gitStashPop({ input: { projectId } })), onSuccess: done }),
    setRemote: useMutation({
      mutationFn: async ({ name, url }: { name: string; url: string }) => unwrap(await gitSetRemote({ input: { projectId, name, url } })),
      onSuccess: done,
    }),
    fetch: useMutation({ mutationFn: async () => unwrap(await gitFetch({ input: { projectId } })), onSuccess: done }),
    pull: useMutation({ mutationFn: async () => unwrap(await gitPull({ input: { projectId } })), onSuccess: done }),
    push: useMutation({ mutationFn: async () => unwrap(await gitPush({ input: { projectId } })), onSuccess: done }),
  };
}
