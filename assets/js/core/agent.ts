// The native kernel's settings (the topmost description layer, from the
// database) and the person's global agent files — DOM-free hooks.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  agentSettings,
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
