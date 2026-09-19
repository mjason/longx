import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { ThreadRow } from "@/core/chat/threadList";
import {
  agentDefinition,
  type AgentDefinitionFields,
  createProject,
  getProject,
  gitInfo,
  initGit,
  createDirectory,
  listDirectory,
  listModels,
  listRunningThreads,
  setGoal,
  clearGoal,
  listProjects,
  listSubagents,
  getThread,
  listThreads,
  startThread,
  type AshRpcError,
  type ListModelsFields,
  directory,
  setThreadHandle,
} from "@/ash_rpc";

export const projectFields = [
  "id",
  "slug",
  "name",
  "description",
  "rootPath",
  "webSearch",
  "modelId",
  "trustLocalAgent",
  "agentSettings",
  "archivedAt",
  "updatedAt",
] as const;

export const threadFields = [
  "id",
  "kernelThreadId",
  "title",
  "handle",
  "preview",
  "status",
  "modelSlug",
  "reasoningEffort",
  "webSearch",
  "lastActivityAt",
  "insertedAt",
] as const;

/** the sub-agents a thread spawned (their rows live under the parent, never in the project list) */
export const subagentFields = [
  "id",
  "kernelThreadId",
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
  threads: (id: string) => ["project", id, "threads"] as const,
  models: ["models"] as const,
  subagents: (threadId: string) => ["subagents", threadId] as const,
  running: ["running-threads"] as const,
};

/** goal mode: set / change (objective, status, budget) or clear the thread's goal. */
export function useGoalActions(threadId: string | undefined) {
  const set = useMutation({
    mutationFn: async (input: { objective?: string; status?: "active" | "paused" | "complete"; tokenBudget?: number | null }) => {
      if (!threadId) throw new Error("no thread");
      return unwrap(await setGoal({ fields: ["objective", "status", "tokenBudget", "tokensUsed", "timeUsedSeconds"], input: { threadId, ...input } }));
    },
  });
  const clear = useMutation({
    mutationFn: async () => {
      if (!threadId) throw new Error("no thread");
      return unwrap(await clearGoal({ fields: ["cleared"], input: { threadId } }));
    },
  });
  return { set, clear };
}

/** The native kernel's layered agent definition of a project (the settings page). */
export type AgentDefinition = {
  present: boolean;
  trusted: boolean;
  dir: string;
  model: string | null;
  effort: string | null;
  plugs: string[];
  files: string[];
  /** what .longx/local/ holds, relative to it — the candidates for promotion */
  localFiles: string[];
  /** the declared roles (shipped, global, the project's), each with its summary and layer */
  agents: { name: string; summary: string; layer: string }[];
  /** the kernel settings in force for the project (global + overrides) */
  settings: AgentSettingsView;
  /** the project's own overrides (null = inherit) */
  overrides: Partial<AgentSettingsView>;
  errors: string[];
};

export type AgentSettingsView = {
  maxDepth: number | null;
  maxChildren: number | null;
  idleMinutes: number | null;
  modelRetries: number | null;
  commandOomPriority: number | null;
  commandMemoryPercent: number | null;
  memoryFloorPercent: number | null;
  childModel: string | null;
  childEffort: string | null;
};

const agentSettingsViewFields = ["maxDepth", "maxChildren", "idleMinutes", "modelRetries", "commandOomPriority", "commandMemoryPercent", "memoryFloorPercent", "childModel", "childEffort"] as const;

// `agents` is an untyped array on the wire (ash_typescript 0.18 selects nothing inside one)
const agentDefinitionFields = [
  "present", "trusted", "dir", "model", "effort", "plugs", "files", "localFiles", "agents", "errors",
  { settings: [...agentSettingsViewFields] },
  { overrides: [...agentSettingsViewFields] },
] as const satisfies AgentDefinitionFields;

export function useAgentDefinition(projectId: string | undefined) {
  return useQuery({
    queryKey: ["project", projectId, "agent-definition"] as const,
    queryFn: async () =>
      unwrap(
        await agentDefinition({ fields: [...agentDefinitionFields], input: { id: projectId! } }),
      ) as AgentDefinition,
    enabled: !!projectId,
    staleTime: 10_000,
  });
}

/** A thread with a turn in flight, anywhere (the welcome page's way back in). */
export type RunningThread = {
  id: string;
  kernelThreadId: string;
  title: string | null;
  preview: string | null;
  lastActivityAt: string | null;
  projectId: string;
  projectSlug: string;
  projectName: string;
  /** a tool holds a question for the person (an ask waiting to be answered) */
  waiting: boolean;
  /** the sub-agents at work while the thread itself is idle */
  working?: string[];
};

/** Every running thread, refreshed every few seconds while the caller shows. */
export function useRunningThreads(intervalMs = 3000) {
  return useQuery({
    queryKey: queryKeys.running,
    queryFn: async () =>
      unwrap(await listRunningThreads({ fields: ["threads"] })).threads as RunningThread[],
    refetchInterval: intervalMs,
  });
}

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

/** One thread by id — a sub-agent's row, which the project list hides, for its own page. */
/** a session of the project's directory (Longx.Projects.directory/2) */
export type SessionEntry = {
  threadId: string;
  kernelThreadId: string;
  projectId: string;
  projectSlug: string | false | null;
  address: string;
  handle: string | null;
  title: string | null;
  preview: string | null;
  state: "running" | "waiting" | "idle" | "asleep" | "archived" | "unrecoverable";
  goal: { objective: string; status: string | null } | null;
  team: string[];
  lastActivityAt: string | null;
};

/** the project's sessions with their live state; refreshed while shown */
export function useSessions(projectId: string | undefined) {
  return useQuery({
    queryKey: ["sessions", projectId ?? ""] as const,
    enabled: !!projectId,
    refetchInterval: 5_000,
    queryFn: async () =>
      unwrap(await directory({ fields: ["sessions"], input: { projectId: projectId! } })).sessions as SessionEntry[],
  });
}

/** the person names a session: its handle (null takes it away) */
export function useSetThreadHandle(projectId: string | undefined) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async ({ threadId, handle }: { threadId: string; handle: string | null }) =>
      unwrap(await setThreadHandle({ fields: ["id", "handle"], input: { threadId, handle } })),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["sessions", projectId ?? ""] });
      if (projectId) client.invalidateQueries({ queryKey: queryKeys.threads(projectId) });
      client.invalidateQueries({ queryKey: ["thread"] });
    },
  });
}

export function useThread(id: string | undefined) {
  return useQuery({
    queryKey: ["thread", id ?? ""] as const,
    enabled: !!id,
    retry: false,
    queryFn: async () =>
      unwrap(await getThread({ fields: [...threadFields, "parentThreadId", "agentPath"], input: { id: id! } })),
  });
}

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

/** The models a turn can pick from (Longx.AI); slug is what the kernel is told. */
export function useModels() {
  return useQuery({
    queryKey: queryKeys.models,
    staleTime: 60_000,
    queryFn: async () => unwrap(await listModels({ fields: modelFields })),
  });
}

export type NewProjectInput = {
  name: string;
  rootPath: string;
  description?: string;
  initGit?: boolean;
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

/** what a new chat starts with: the web-search switch, and the model / reasoning level when picked */
export type StartThreadInput = {
  webSearch?: boolean;
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
    onSuccess: (row) => {
      // the page moves to the new thread as soon as this resolves: the row
      // goes into the list now, before the refetch lands, or the thread page
      // would show "not found" for a moment
      client.setQueryData<ThreadRow[]>(queryKeys.threads(id), (rows) =>
        rows && !rows.some((r) => r.id === row.id) ? [row, ...rows] : rows,
      );
      client.invalidateQueries({ queryKey: queryKeys.threads(id) });
    },
  });
}
