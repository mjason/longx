// Project data for the screens: TanStack Query over the generated client.
// Everything here is DOM-free (the phone app reuses it).
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  codexInfo,
  createProject,
  getProject,
  gitInfo,
  initGit,
  listDirectory,
  listModels,
  listProjects,
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
  "dirtyStart",
  "tools",
  "memoryLimitMb",
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
  "lastActivityAt",
  "insertedAt",
] as const;

export const gitFields = ["repository", "head", "clean", "changes", "lfs"] as const;
export const codexFields = ["home", "exists", "bytes", "files", "worker"] as const;

/** An RPC failure as an Error the UI can show; field errors keep their names. */
export class RpcFailure extends Error {
  errors: AshRpcError[];
  constructor(errors: AshRpcError[]) {
    super(errors.map((e) => e.message).join("; ") || "request failed");
    this.errors = errors;
  }
  fieldErrors(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const e of this.errors) for (const f of e.fields ?? []) out[f] ??= e.message;
    return out;
  }
}

export function unwrap<T>(result: { success: true; data: T } | { success: false; errors: AshRpcError[] }): T {
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
};

export function useProjects() {
  return useQuery({
    queryKey: queryKeys.projects,
    queryFn: async () => unwrap(await listProjects({ fields: [...projectFields] })),
  });
}

export function useProject(slug: string) {
  return useQuery({
    queryKey: queryKeys.project(slug),
    queryFn: async () => unwrap(await getProject({ fields: [...projectFields], input: { slug } })),
  });
}

export function useGitInfo(id: string | undefined) {
  return useQuery({
    queryKey: queryKeys.git(id ?? ""),
    enabled: !!id,
    queryFn: async () => unwrap(await gitInfo({ fields: [...gitFields], input: { id: id! } })),
  });
}

export function useCodexInfo(id: string | undefined) {
  return useQuery({
    queryKey: queryKeys.codex(id ?? ""),
    enabled: !!id,
    queryFn: async () => unwrap(await codexInfo({ fields: [...codexFields], input: { id: id! } })),
  });
}

export function useThreads(id: string | undefined) {
  return useQuery({
    queryKey: queryKeys.threads(id ?? ""),
    enabled: !!id,
    queryFn: async () =>
      unwrap(await listThreads({ fields: [...threadFields], input: { projectId: id! } })),
  });
}

export const modelFields: ListModelsFields = ["id", "name", "slug", "default", "reasoningEffort", { provider: ["name"] }];

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
    queryFn: async () => unwrap(await sandboxStatus({ fields: ["status", "reason", "checkedAt"] })),
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
    mutationFn: async () => unwrap(await initGit({ fields: [...gitFields], input: { id } })),
    onSuccess: (data) => client.setQueryData(queryKeys.git(id), data),
  });
}

export function useStartThread(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async () =>
      unwrap(await startThread({ fields: [...threadFields], input: { projectId: id } })),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: queryKeys.threads(id) });
      client.invalidateQueries({ queryKey: queryKeys.codex(id) });
    },
  });
}

export function useCodexControls(id: string) {
  const client = useQueryClient();
  const refresh = () => client.invalidateQueries({ queryKey: queryKeys.codex(id) });
  const stop = useMutation({
    mutationFn: async (force: boolean) => unwrap(await stopCodex({ input: { id, force } })),
    onSuccess: refresh,
  });
  const restart = useMutation({
    mutationFn: async () => unwrap(await restartCodex({ input: { id } })),
    onSuccess: refresh,
  });
  return { stop, restart };
}
