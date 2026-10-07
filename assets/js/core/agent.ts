// The native kernel's settings (the topmost description layer, from the
// database) and the person's global agent files — DOM-free hooks.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  agentSettings,
  commandGuardStatus,
  extensionInventory,
  extensionFiles,
  previewLocal,
  promoteLocal,
  publicUrl,
  setAgentSettings,
  setPublicUrl,
} from "@/core/api";
import type { SetAgentSettingsInput } from "@/gql/graphql";
import { unwrap } from "@/core/projects";

export type AgentSettings = {
  maxDepth: number;
  maxChildren: number;
  idleMinutes: number;
  modelRetries: number;
  commandOomPriority: number;
  memoryFloorPercent: number;
  commandCgroupMode: "auto" | "off" | "required";
  commandMemoryLimitPercent: number;
  commandSwapLimitMb: number;
  commandShell: "auto" | "bash" | "zsh";
  extraPath: string;
  defaultExtraPath: string;
  childModel: string | null;
  childEffort: string | null;
};

/** A project's overrides: every field optional, null = inherit the global value. */
export type AgentOverrides = Partial<{ [K in keyof AgentSettings]: AgentSettings[K] | null }>;

export const agentSettingsFields = ["maxDepth", "maxChildren", "idleMinutes", "modelRetries", "commandOomPriority", "memoryFloorPercent", "commandCgroupMode", "commandMemoryLimitPercent", "commandSwapLimitMb", "childModel", "childEffort"] as const;

export const agentKeys = {
  all: ["agent-kernel"] as const,
  settings: ["agent-kernel", "settings"] as const,
  files: ["agent-kernel", "files"] as const,
  file: (path: string) => ["agent-kernel", "file", path] as const,
};

export function useAgentSettings() {
  return useQuery({
    queryKey: agentKeys.settings,
    queryFn: async () => unwrap(await agentSettings()) as AgentSettings,
  });
}

export type CommandGuardStatus = {
  mode: "auto" | "off" | "required";
  platform: string;
  capability: "off" | "unsupported" | "eligible" | "unavailable";
  reason: string | null;
  path: string | null;
  activeTasks: number;
  cleanupPendingTasks: number;
  lastTaskStatus: string | null;
  lastTaskReason: string | null;
  lastTaskPath: string | null;
  lastOomKill: number | null;
  lastPopulated: boolean | null;
  lastCleanupError: string | null;
  lastObservedAt: string | null;
  checkedAt: string;
};

export function useCommandGuardStatus(projectId?: string) {
  return useQuery({
    queryKey: [...agentKeys.all, "command-guard", projectId ?? null],
    queryFn: async () => unwrap(await commandGuardStatus({ input: projectId ? { projectId } : {} })) as CommandGuardStatus,
    refetchInterval: 5_000,
  });
}

function useAgentWrite<TArgs, TResult>(fn: (args: TArgs) => Promise<TResult>) {
  const client = useQueryClient();
  return useMutation({ mutationFn: fn, onSuccess: () => void client.invalidateQueries({ queryKey: agentKeys.all }) });
}

export function useAgentSettingsActions() {
  return {
    save: useAgentWrite(async (input: SetAgentSettingsInput) => unwrap(await setAgentSettings({ input })) as AgentSettings),
  };
}

/** Moves a file of the project's .longx/local/ tree into .longx/shared/. */
export function usePromoteLocal(projectId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async ({ path, digest }: { path: string; digest: string }) =>
      unwrap(await promoteLocal({ input: { id: projectId, path, digest } })) as { path: string },
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ["project", projectId] });
      void client.invalidateQueries({ queryKey: ["files", projectId] });
      void client.invalidateQueries({ queryKey: ["git", projectId] });
      void client.invalidateQueries({ queryKey: ["watches"] });
    },
  });
}

export type ExtensionItem = {
  name: string; kind: "definition" | "agents" | "plugs" | "watches" | "knowledge" | "artifacts";
  path: string; layer: "local" | "shared" | "project"; shareable: boolean; complete: boolean;
};
export type PromotionPreview = {
  path: string; target: string; digest: string; conflicts: string[]; canShare: boolean;
  files: { source: string; target: string; size: number; hash: string; content: string | null; truncated: boolean; binary: boolean }[];
};
export function useExtensions(projectId: string) {
  return useQuery({
    queryKey: ["project", projectId, "extensions"],
    queryFn: async () => unwrap(await extensionInventory({ input: { id: projectId } })) as ExtensionItem[],
  });
}
export function usePromotionPreview(projectId: string, path: string | null) {
  return useQuery({
    queryKey: ["project", projectId, "promotion-preview", path],
    enabled: path !== null,
    staleTime: 0,
    gcTime: 0,
    queryFn: async () => unwrap(await previewLocal({ input: { id: projectId, path: path! } })) as PromotionPreview,
  });
}

export function useExtensionFiles(projectId: string, path: string | null) {
  return useQuery({
    queryKey: ["project", projectId, "extension-files", path],
    enabled: path !== null,
    queryFn: async () => unwrap(await extensionFiles({ input: { id: projectId, path: path! } })) as {
      name: string; path: string; kind: "file" | "dir"; size: number;
    }[],
  });
}

/** the address a login sends the person back to: the setting, else where the browser came from */
export type PublicUrl = { url: string; setting: string | null };

export function usePublicUrl() {
  return useQuery({
    queryKey: ["agent-kernel", "public-url"] as const,
    queryFn: async () => unwrap(await publicUrl()) as PublicUrl,
  });
}

export function usePublicUrlActions() {
  return {
    save: useAgentWrite(async (url: string) => unwrap(await setPublicUrl({ input: { url } })) as PublicUrl),
  };
}
