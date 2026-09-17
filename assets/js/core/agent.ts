// The native kernel's settings (the topmost description layer, from the
// database) and the person's global agent files — DOM-free hooks.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  agentDeleteFile,
  agentFiles,
  agentReadFile,
  agentSettings,
  agentWriteFile,
  promoteLocal,
  publicUrl,
  setAgentSettings,
  setPublicUrl,
  type SetAgentSettingsInput,
} from "@/ash_rpc";
import { unwrap } from "@/core/projects";

export type AgentSettings = {
  maxDepth: number;
  maxChildren: number;
  idleMinutes: number;
  childModel: string | null;
  childEffort: string | null;
  reviewerModel: string | null;
  reviewerEffort: string | null;
};

/** A project's overrides: every field optional, null = inherit the global value. */
export type AgentOverrides = Partial<{ [K in keyof AgentSettings]: AgentSettings[K] | null }>;

export const agentSettingsFields = ["maxDepth", "maxChildren", "idleMinutes", "childModel", "childEffort", "reviewerModel", "reviewerEffort"] as const;

export const agentKeys = {
  all: ["agent-kernel"] as const,
  settings: ["agent-kernel", "settings"] as const,
  files: ["agent-kernel", "files"] as const,
  file: (path: string) => ["agent-kernel", "file", path] as const,
};

export function useAgentSettings() {
  return useQuery({
    queryKey: agentKeys.settings,
    queryFn: async () => unwrap(await agentSettings({ fields: [...agentSettingsFields] })) as AgentSettings,
  });
}

function useAgentWrite<TArgs, TResult>(fn: (args: TArgs) => Promise<TResult>) {
  const client = useQueryClient();
  return useMutation({ mutationFn: fn, onSuccess: () => void client.invalidateQueries({ queryKey: agentKeys.all }) });
}

export function useAgentSettingsActions() {
  return {
    save: useAgentWrite(async (input: SetAgentSettingsInput) => unwrap(await setAgentSettings({ fields: [...agentSettingsFields], input })) as AgentSettings),
  };
}

export type AgentFile = { path: string; size: number };

export function useAgentFiles() {
  return useQuery({
    queryKey: agentKeys.files,
    queryFn: async () => unwrap(await agentFiles({ fields: ["path", "size"] })) as AgentFile[],
  });
}

export function useAgentFile(path: string | null) {
  return useQuery({
    queryKey: agentKeys.file(path ?? ""),
    queryFn: async () => (unwrap(await agentReadFile({ fields: ["text"], input: { path: path! } })) as { text: string }).text,
    enabled: path !== null,
  });
}

export function useAgentFileActions() {
  return {
    write: useAgentWrite(async ({ path, content }: { path: string; content: string }) => unwrap(await agentWriteFile({ input: { path, content } }))),
    remove: useAgentWrite(async (path: string) => unwrap(await agentDeleteFile({ input: { path } }))),
  };
}

/** Moves a file of the project's .longx/local/ tree into .longx/shared/. */
export function usePromoteLocal(projectId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (path: string) => unwrap(await promoteLocal({ fields: ["path"], input: { id: projectId, path } })) as { path: string },
    onSuccess: () => void client.invalidateQueries({ queryKey: ["project", projectId, "agent-definition"] }),
  });
}

/** the address a login sends the person back to: the setting, else where the browser came from */
export type PublicUrl = { url: string; setting: string | null };

export function usePublicUrl() {
  return useQuery({
    queryKey: ["agent-kernel", "public-url"] as const,
    queryFn: async () => unwrap(await publicUrl({ fields: ["url", "setting"] })) as PublicUrl,
  });
}

export function usePublicUrlActions() {
  return {
    save: useAgentWrite(async (url: string) => unwrap(await setPublicUrl({ fields: ["url", "setting"], input: { url } })) as PublicUrl),
  };
}
