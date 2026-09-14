// Project data for the screens: TanStack Query over the generated client.
// Everything here is DOM-free (the phone app reuses it).
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  codexInfo,
  createProject,
  getProject,
  gitInfo,
  initGit,
  createDirectory,
  listDirectory,
  listModels,
  listTurns,
  redoTurn,
  restoreFiles,
  restoreProposal,
  listProjects,
  listSubagents,
  listThreads,
  restartCodex,
  sandboxStatus,
  startThread,
  stopCodex,
  type AshRpcError,
  type ListModelsFields,
} from "@/ash_rpc";

export const projectFields = [
  "id",
  "slug",
  "name",
  "description",
  "rootPath",
  "sandbox",
  "approvalPolicy",
  "networkAccess",
  "writableRoots",
  "webSearch",
  "multiAgent",
  "globalMemory",
  "dirtyStart",
  "tools",
  "memoryLimitMb",
  "modelId",
  "archivedAt",
  "updatedAt",
] as const;

export const threadFields = [
  "id",
  "codexThreadId",
  "title",
  "preview",
  "status",
  "modelSlug",
  "reasoningEffort",
  "sandbox",
  "approvalPolicy",
  "networkAccess",
  "webSearch",
  "multiAgent",
  "lastActivityAt",
  "insertedAt",
] as const;

/** codex-spawned sub-agents of a thread (their rows live under the parent, never in the project list) */
export const subagentFields = [
  "id",
  "codexThreadId",
  "title",
  "preview",
  "status",
  "agentPath",
  "lastActivityAt",
  "insertedAt",
] as const;

export const gitFields = [
  "repository",
  "head",
  "clean",
  "changes",
  "lfs",
] as const;
export const codexFields = [
  "home",
  "exists",
  "bytes",
  "files",
  "worker",
  "stale",
] as const;

/** An RPC failure as an Error the UI can show; field errors keep their names. */
export class RpcFailure extends Error {
  errors: AshRpcError[];
  constructor(errors: AshRpcError[]) {
    super(errors.map((e) => e.message).join("; ") || "request failed");
    this.errors = errors;
  }
  fieldErrors(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const e of this.errors)
      for (const f of e.fields ?? []) out[f] ??= e.message;
    return out;
  }
}

export function unwrap<T>(
  result:
    { success: true; data: T } | { success: false; errors: AshRpcError[] },
): T {
  if (result.success) return result.data;
  throw new RpcFailure(result.errors);
}

export const queryKeys = {
  projects: ["projects"] as const,
  project: (slug: string) => ["project", slug] as const,
  git: (id: string) => ["project", id, "git"] as const,
  codex: (id: string) => ["project", id, "codex"] as const,
  threads: (id: string) => ["project", id, "threads"] as const,
  sandbox: ["sandbox"] as const,
  models: ["models"] as const,
  turns: (threadId: string) => ["turns", threadId] as const,
  subagents: (threadId: string) => ["subagents", threadId] as const,
};

export function useProjects() {
  return useQuery({
    queryKey: queryKeys.projects,
    queryFn: async () =>
      unwrap(await listProjects({ fields: [...projectFields] })),
  });
}

export function useProject(slug: string) {
  return useQuery({
    queryKey: queryKeys.project(slug),
    queryFn: async () =>
      unwrap(await getProject({ fields: [...projectFields], input: { slug } })),
  });
}

export function useGitInfo(id: string | undefined) {
  return useQuery({
    queryKey: queryKeys.git(id ?? ""),
    enabled: !!id,
    queryFn: async () =>
      unwrap(await gitInfo({ fields: [...gitFields], input: { id: id! } })),
  });
}

export function useCodexInfo(id: string | undefined) {
  return useQuery({
    queryKey: queryKeys.codex(id ?? ""),
    enabled: !!id,
    queryFn: async () =>
      unwrap(await codexInfo({ fields: [...codexFields], input: { id: id! } })),
    // `stale` (settings changed under the running codex) is checked server-side per call
    refetchInterval: 30_000,
  });
}

export function useThreads(id: string | undefined) {
  return useQuery({
    queryKey: queryKeys.threads(id ?? ""),
    enabled: !!id,
    queryFn: async () =>
      unwrap(
        await listThreads({
          fields: [...threadFields],
          input: { projectId: id! },
        }),
      ),
  });
}

export const turnFields = [
  "id",
  "codexTurnId",
  "userText",
  "modelSlug",
  "status",
  "startedAt",
  "completedAt",
  "commitBefore",
  "commitAfter",
  "dirtyStart",
  "diff",
  "error",
] as const;

/** The turns of a thread, oldest first (reverted ones included when asked). */
export function useSubagents(threadId: string | undefined) {
  return useQuery({
    queryKey: queryKeys.subagents(threadId ?? ""),
    enabled: !!threadId,
    queryFn: async () =>
      unwrap(
        await listSubagents({
          fields: [...subagentFields],
          input: { parentThreadId: threadId! },
        }),
      ),
  });
}

export function useTurns(
  threadId: string | undefined,
  includeReverted = false,
) {
  return useQuery({
    queryKey: [...queryKeys.turns(threadId ?? ""), includeReverted],
    enabled: !!threadId,
    queryFn: async () =>
      unwrap(
        await listTurns({
          fields: [...turnFields],
          input: { threadId: threadId!, includeReverted },
        }),
      ),
  });
}

export type RestoreProposal = {
  commit: string;
  dirtyNow: boolean;
  changedFiles: string[];
  laterTurns: number;
};

export function fetchRestoreProposal(turnId: string) {
  return restoreProposal({
    fields: ["commit", "dirtyNow", "changedFiles", "laterTurns"],
    input: { turnId },
  }).then(unwrap);
}

export function useRestoreFiles(threadId: string | undefined) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      turnId: string;
      mode?: "restore_tree" | "reset_hard";
    }) =>
      unwrap(
        await restoreFiles({
          fields: ["safetyCommit", "head"],
          input: { ...input, confirm: true },
        }),
      ),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["project"] });
      if (threadId)
        client.invalidateQueries({ queryKey: queryKeys.turns(threadId) });
    },
  });
}

export function useRedoTurn(threadId: string | undefined) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      turnId: string;
      text?: string;
      model?: string;
      mode?: "revert" | "fork";
      restoreFiles?: boolean;
    }) => unwrap(await redoTurn({ fields: ["id", "threadId"], input })),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["project"] });
      if (threadId)
        client.invalidateQueries({ queryKey: queryKeys.turns(threadId) });
    },
  });
}

export const modelFields: ListModelsFields = [
  "id",
  "name",
  "slug",
  "default",
  "contextWindow",
  "reasoningLevels",
  "reasoningEffort",
  { provider: ["name"] },
];

/** The models a turn can pick from (Longx.AI); slug is what codex is told. */
export function useModels() {
  return useQuery({
    queryKey: queryKeys.models,
    staleTime: 60_000,
    queryFn: async () => unwrap(await listModels({ fields: modelFields })),
  });
}

export function useSandboxStatus() {
  return useQuery({
    queryKey: queryKeys.sandbox,
    staleTime: Infinity,
    queryFn: async () =>
      unwrap(
        await sandboxStatus({ fields: ["status", "reason", "bwrap", "gpu", "checkedAt"] }),
      ),
  });
}

export type NewProjectInput = {
  name: string;
  rootPath: string;
  description?: string;
  initGit?: boolean;
  sandbox?: "read_only" | "workspace_write" | "danger_full_access";
  approvalPolicy?: "never" | "on_request" | "untrusted";
  networkAccess?: boolean;
};

export type DirectoryEntry = { name: string; path: string; git: boolean };
export type DirectoryListing = {
  path: string;
  parent: string | null;
  git: boolean;
  entries: DirectoryEntry[];
  roots: DirectoryEntry[];
};

/** The directory picker's listing; `path` null = the server's home directory. */
export function useDirectory(path: string | null, showHidden = false) {
  return useQuery({
    queryKey: ["directory", path, showHidden] as const,
    placeholderData: (prev) => prev,
    queryFn: async () =>
      unwrap(
        await listDirectory({
          fields: ["path", "parent", "git", "entries", "roots"],
          input: { ...(path ? { path } : {}), showHidden },
        }),
      ) as DirectoryListing,
  });
}

/** The picker's "new directory": made under `parent`, the listing refetched. */
export function useCreateDirectory() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: { parent: string; name: string }) =>
      unwrap(await createDirectory({ fields: ["name", "path", "git"], input })),
    onSuccess: () => client.invalidateQueries({ queryKey: ["directory"] }),
  });
}

export function useCreateProject() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: NewProjectInput) =>
      unwrap(await createProject({ fields: [...projectFields], input })),
    onSuccess: () => client.invalidateQueries({ queryKey: queryKeys.projects }),
  });
}

export function useInitGit(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async () =>
      unwrap(await initGit({ fields: [...gitFields], input: { id } })),
    onSuccess: (data) => client.setQueryData(queryKeys.git(id), data),
  });
}

export type StartThreadMode = {
  sandbox: "read_only" | "workspace_write" | "danger_full_access";
  approvalPolicy: "never" | "on_request" | "untrusted";
  networkAccess: boolean;
  webSearch: boolean;
  multiAgent: boolean;
};
/** what a new chat starts with: the mode, and the model / reasoning level when picked (a thread-start config, unlike a mid-thread switch) */
export type StartThreadInput = Partial<StartThreadMode> & {
  model?: string;
  effort?: string;
};

export function useStartThread(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input?: StartThreadInput) =>
      unwrap(
        await startThread({
          fields: [...threadFields],
          input: { projectId: id, ...(input ?? {}) },
        }),
      ),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: queryKeys.threads(id) });
      client.invalidateQueries({ queryKey: queryKeys.codex(id) });
    },
  });
}

export function useCodexControls(id: string) {
  const client = useQueryClient();
  const refresh = () =>
    client.invalidateQueries({ queryKey: queryKeys.codex(id) });
  const stop = useMutation({
    mutationFn: async (force: boolean) =>
      unwrap(await stopCodex({ input: { id, force } })),
    onSuccess: refresh,
  });
  const restart = useMutation({
    mutationFn: async () => unwrap(await restartCodex({ input: { id } })),
    onSuccess: refresh,
  });
  return { stop, restart };
}
