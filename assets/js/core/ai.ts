// The settings page's half of Longx.AI: providers and their models, the
// search provider, the tool switches, plus the sandbox probe. Every write
// invalidates the AI queries and the composer's model list.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  applyPreset,
  checkModel,
  createModel,
  createProvider,
  deleteModel,
  deleteProvider,
  listModels,
  listPresets,
  listProviders,
  listSearchProviders,
  listTools,
  makeDefaultModel,
  memoryDeleteNote,
  memoryIndex,
  memoryNotes,
  memoryRun,
  memorySearch,
  memorySetAutoExtract,
  memoryStatus,
  memoryWriteIndex,
  probeSandbox,
  setToolEnabled,
  updateModel,
  updateProvider,
  updateSearchProvider,
  type CreateModelInput,
  type CreateProviderInput,
  type UpdateModelInput,
  type UpdateProviderInput,
} from "@/ash_rpc";
import { queryKeys, unwrap } from "./projects";

export const aiKeys = {
  all: ["ai"] as const,
  providers: ["ai", "providers"] as const,
  models: ["ai", "models"] as const,
  search: ["ai", "search"] as const,
  tools: ["ai", "tools"] as const,
  presets: ["ai", "presets"] as const,
};

export type Provider = {
  id: string;
  name: string;
  slug: string;
  baseUrl: string;
  kind: "openai" | "openai_compatible";
  hasApiKey: boolean;
  supportsHostedWebSearch: boolean;
  requestTimeoutMs: number;
  maxConcurrentRequests: number | null;
  lastCheckedAt: string | null;
  lastError: string | null;
  lastErrorAt: string | null;
};

export type ModelRow = {
  id: string;
  name: string;
  slug: string | null;
  upstreamId: string;
  contextWindow: number | null;
  default: boolean;
  reasoningLevels: string[];
  reasoningEffort: string | null;
  reasoningSummary: "auto" | "concise" | "detailed" | "none" | null;
  maxOutputTokens: number | null;
  /** the model runs codex's web_search tool itself; null = the provider's say */
  hostedWebSearch: boolean | null;
  providerId: string;
};

/** a ready-made provider (Longx.AI.Presets) with what of it is installed */
export type PresetModel = {
  upstreamId: string;
  slug: string;
  name: string;
  contextWindow: number;
  reasoningLevels: string[];
  reasoningEffort: string | null;
  image: boolean;
  recommended: boolean;
  installed: boolean;
};
export type Preset = {
  slug: string;
  name: string;
  kind: "openai" | "openai_compatible";
  baseUrl: string;
  supportsHostedWebSearch: boolean;
  keyEnv: string;
  keyUrl: string;
  docsUrl: string;
  installed: boolean;
  providerId: string | null;
  models: PresetModel[];
};
export type ApplyPresetInput = {
  slug: string;
  apiKey?: string;
  models: string[];
  makeDefault?: string;
};

export type SearchProviderRow = {
  id: string;
  name: string;
  slug: string;
  kind: string;
  baseUrl: string | null;
  hasApiKey: boolean;
  default: boolean;
};
export type ToolRow = {
  id: string;
  namespace: string;
  name: string;
  qualifiedName: string;
  description: string;
  enabled: boolean;
};
export type SandboxReport = {
  status: "ok" | "unavailable";
  reason: string | null;
  checkedAt: string;
};

const providerFields = [
  "id",
  "name",
  "slug",
  "baseUrl",
  "kind",
  "hasApiKey",
  "supportsHostedWebSearch",
  "requestTimeoutMs",
  "maxConcurrentRequests",
  "lastCheckedAt",
  "lastError",
  "lastErrorAt",
] as const;
const modelRowFields = [
  "id",
  "name",
  "slug",
  "upstreamId",
  "contextWindow",
  "default",
  "reasoningLevels",
  "reasoningEffort",
  "reasoningSummary",
  "maxOutputTokens",
  "hostedWebSearch",
  "providerId",
] as const;
const presetFields = [
  "slug",
  "name",
  "kind",
  "baseUrl",
  "supportsHostedWebSearch",
  "keyEnv",
  "keyUrl",
  "docsUrl",
  "installed",
  "providerId",
  "models",
] as const;

export function useProviders() {
  return useQuery({
    queryKey: aiKeys.providers,
    queryFn: async () =>
      unwrap(
        await listProviders({ fields: [...providerFields] }),
      ) as Provider[],
  });
}

/** every model with its settings (the composer's `useModels` is the lighter list) */
export function useModelRows() {
  return useQuery({
    queryKey: aiKeys.models,
    queryFn: async () =>
      unwrap(await listModels({ fields: [...modelRowFields] })) as ModelRow[],
  });
}

export function useSearchProviders() {
  return useQuery({
    queryKey: aiKeys.search,
    queryFn: async () =>
      unwrap(
        await listSearchProviders({
          fields: [
            "id",
            "name",
            "slug",
            "kind",
            "baseUrl",
            "hasApiKey",
            "default",
          ],
        }),
      ) as SearchProviderRow[],
  });
}

export function usePresets() {
  return useQuery({
    queryKey: aiKeys.presets,
    queryFn: async () =>
      unwrap(await listPresets({ fields: [...presetFields] })) as Preset[],
  });
}

export function useTools() {
  return useQuery({
    queryKey: aiKeys.tools,
    queryFn: async () =>
      unwrap(
        await listTools({
          fields: [
            "id",
            "namespace",
            "name",
            "qualifiedName",
            "description",
            "enabled",
          ],
        }),
      ) as ToolRow[],
  });
}

function useAiWrite<TArgs, TResult>(fn: (args: TArgs) => Promise<TResult>) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: aiKeys.all });
      void client.invalidateQueries({ queryKey: queryKeys.models });
    },
  });
}

export type ProviderInput = CreateProviderInput;
export type ProviderPatch = UpdateProviderInput;
export type ModelInput = CreateModelInput;
export type ModelPatch = UpdateModelInput;

export function useAiActions() {
  return {
    createProvider: useAiWrite(async (input: ProviderInput) =>
      unwrap(await createProvider({ fields: ["id"], input })),
    ),
    updateProvider: useAiWrite(
      async ({ id, input }: { id: string; input: ProviderPatch }) =>
        unwrap(await updateProvider({ fields: ["id"], identity: id, input })),
    ),
    deleteProvider: useAiWrite(async (id: string) =>
      unwrap(await deleteProvider({ identity: id })),
    ),
    applyPreset: useAiWrite(
      async (input: ApplyPresetInput) =>
        unwrap(
          await applyPreset({ fields: ["providerId", "modelIds"], input }),
        ) as { providerId: string; modelIds: string[] },
    ),
    createModel: useAiWrite(async (input: ModelInput) =>
      unwrap(await createModel({ fields: ["id"], input })),
    ),
    updateModel: useAiWrite(
      async ({ id, input }: { id: string; input: ModelPatch }) =>
        unwrap(await updateModel({ fields: ["id"], identity: id, input })),
    ),
    deleteModel: useAiWrite(async (id: string) =>
      unwrap(await deleteModel({ identity: id })),
    ),
    makeDefault: useAiWrite(async (id: string) =>
      unwrap(await makeDefaultModel({ fields: ["id"], identity: id })),
    ),
    checkModel: useAiWrite(
      async (id: string) =>
        unwrap(
          await checkModel({
            fields: ["ok", "latencyMs", "error"],
            input: { id },
          }),
        ) as { ok: boolean; latencyMs: number | null; error: string | null },
    ),
    setSearchKey: useAiWrite(
      async ({ id, apiKey }: { id: string; apiKey: string }) =>
        unwrap(
          await updateSearchProvider({
            fields: ["id"],
            identity: id,
            input: { apiKey },
          }),
        ),
    ),
    setToolEnabled: useAiWrite(
      async ({ id, enabled }: { id: string; enabled: boolean }) =>
        unwrap(
          await setToolEnabled({
            fields: ["id"],
            identity: id,
            input: { enabled },
          }),
        ),
    ),
  };
}

/** runs the bwrap probe again and hands back the report (the cached status query is refreshed) */
export function useProbeSandbox() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async () =>
      unwrap(
        await probeSandbox({ fields: ["status", "reason", "bwrap", "gpu", "presets", "platform", "home", "checkedAt"] }),
      ) as SandboxReport,
    onSuccess: (report) => client.setQueryData(queryKeys.sandbox, report),
  });
}

// ---- the global memory (Longx.Memory) ----

export type MemoryNote = {
  file: string;
  at: string | null;
  project: string | null;
  thread: string | null;
  source: string | null;
  text: string;
};
export type MemoryHit = { file: string; line: number; text: string };
export type MemoryStatus = {
  autoExtract: boolean;
  lastRunAt: string | null;
  lastError: string | null;
  pending: number;
  folded: number;
};

export const memoryKeys = {
  all: ["memory"] as const,
  index: ["memory", "index"] as const,
  notes: ["memory", "notes"] as const,
  status: ["memory", "status"] as const,
  search: (q: string) => ["memory", "search", q] as const,
};

export function useMemoryIndex() {
  return useQuery({
    queryKey: memoryKeys.index,
    queryFn: async () =>
      (unwrap(await memoryIndex({ fields: ["text"] })) as { text: string })
        .text,
  });
}

export function useMemoryNotes() {
  return useQuery({
    queryKey: memoryKeys.notes,
    queryFn: async () =>
      unwrap(
        await memoryNotes({
          fields: ["file", "at", "project", "thread", "source", "text"],
        }),
      ) as MemoryNote[],
  });
}

export function useMemoryStatus() {
  return useQuery({
    queryKey: memoryKeys.status,
    queryFn: async () =>
      unwrap(
        await memoryStatus({
          fields: ["autoExtract", "lastRunAt", "lastError", "pending", "folded"],
        }),
      ) as MemoryStatus,
    refetchInterval: 30_000,
  });
}

export function useMemorySearch(query: string) {
  return useQuery({
    queryKey: memoryKeys.search(query),
    enabled: query.trim().length > 0,
    queryFn: async () =>
      unwrap(
        await memorySearch({
          fields: ["file", "line", "text"],
          input: { query },
        }),
      ) as MemoryHit[],
  });
}

function useMemoryWrite<TArgs, TResult>(fn: (args: TArgs) => Promise<TResult>) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: () =>
      void client.invalidateQueries({ queryKey: memoryKeys.all }),
  });
}

export function useMemoryActions() {
  return {
    writeIndex: useMemoryWrite(async (text: string) =>
      unwrap(await memoryWriteIndex({ input: { text } })),
    ),
    deleteNote: useMemoryWrite(async (file: string) =>
      unwrap(await memoryDeleteNote({ input: { file } })),
    ),
    setAutoExtract: useMemoryWrite(async (enabled: boolean) =>
      unwrap(await memorySetAutoExtract({ input: { enabled } })),
    ),
    run: useMemoryWrite(async () => unwrap(await memoryRun({}))),
  };
}
