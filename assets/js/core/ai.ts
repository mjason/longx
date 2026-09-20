// The settings page's half of Longx.AI: providers and their models, the
// search provider, the aliases, the knowledge docs. Every write invalidates
// the AI queries and the composer's model list.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  knowledgeDelete,
  knowledgeDocs,
  knowledgeRead,
  knowledgeWrite,
  applyPreset,
  checkModel,
  createModel,
  createProvider,
  deleteModel,
  deleteProvider,
  discoverModels,
  listModels,
  listPresets,
  listProviders,
  listSearchProviders,
  modelAliases,
  setModelAlias,
  deleteModelAlias,
  makeDefaultModel,
  updateModel,
  updateProvider,
  updateSearchProvider,
  type CreateModelInput,
  type CreateProviderInput,
  type UpdateModelInput,
  type UpdateProviderInput,
  defaultModelSetting,
  setDefaultModel,
} from "@/ash_rpc";
import { queryKeys, unwrap } from "./projects";

export const aiKeys = {
  all: ["ai"] as const,
  providers: ["ai", "providers"] as const,
  models: ["ai", "models"] as const,
  search: ["ai", "search"] as const,
  presets: ["ai", "presets"] as const,
  aliases: ["ai", "aliases"] as const,
  defaultModel: ["ai", "default-model"] as const,
};

/** a tier (ultra / pro / plus, always there) or a team's alias: a chain of model slugs, the first used, the rest fallbacks */
export type ModelAlias = { name: string; label: string; models: string[]; builtin: boolean };

/** the default model: a name (a tier, an alias, a slug) and what it resolves to now */
export type DefaultModel = { name: string; slug: string | null; kind: "tier" | "alias" | "model" };

export function useDefaultModel() {
  return useQuery({
    queryKey: aiKeys.defaultModel,
    queryFn: async () => unwrap(await defaultModelSetting({ fields: ["name", "slug", "kind"] })) as DefaultModel,
  });
}

export function useModelAliases() {
  return useQuery({
    queryKey: aiKeys.aliases,
    queryFn: async () => unwrap(await modelAliases({ fields: ["name", "label", "models", "builtin"] })) as ModelAlias[],
  });
}

/** a model the provider's own list names (GET /models), normalised by the server */
export type DiscoveredModel = {
  id: string;
  name: string;
  ownedBy: string | null;
  contextWindow: number | null;
  reasoningLevels: string[];
  reasoningEffort: string | null;
  imageInput: boolean;
  installed: boolean;
};

export type Discovery = { ok: boolean; error: string | null; models: DiscoveredModel[] };

/** the provider's own model list, fetched when asked (never cached across openings) */
export function useDiscoverModels(providerId: string | null) {
  return useQuery({
    queryKey: ["ai", "discover", providerId] as const,
    queryFn: async () =>
      unwrap(await discoverModels({ fields: ["ok", "error", "models"], input: { id: providerId! } })) as Discovery,
    enabled: providerId !== null,
    staleTime: 0,
    gcTime: 0,
  });
}

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
  /** an OAuth2 credential standing in for the key (a ChatGPT subscription) */
  credentialId: string | null;
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
  /** the model's provider searches the web on its side; null = the provider's say */
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
  /** the key is a login, not a string: apply makes the credential, then the person logs in */
  credential: boolean;
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
  "credentialId",
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
  "credential",
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
          await applyPreset({ fields: ["providerId", "modelIds", "credentialId"], input }),
        ) as { providerId: string; modelIds: string[]; credentialId: string | null },
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
    setDefaultModel: useAiWrite(async (name: string) =>
      unwrap(await setDefaultModel({ fields: ["name", "slug", "kind"], input: { name } })) as DefaultModel,
    ),
    setModelAlias: useAiWrite(async (input: { name: string; models: string[] }) =>
      unwrap(await setModelAlias({ fields: ["name", "label", "models", "builtin"], input })),
    ),
    deleteModelAlias: useAiWrite(async (name: string) => unwrap(await deleteModelAlias({ input: { name } }))),
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
  };
}

/** The kernel's knowledge: Longx's shipped docs (read-only) and the person's global root. */
export type KnowledgeDoc = { root: string; path: string; title: string; summary: string; tags: string[]; always: boolean; writable: boolean };

export const knowledgeKeys = {
  all: ["knowledge"] as const,
  docs: ["knowledge", "docs"] as const,
  doc: (path: string) => ["knowledge", "doc", path] as const,
};

export function useKnowledgeDocs() {
  return useQuery({
    queryKey: knowledgeKeys.docs,
    queryFn: async () =>
      unwrap(await knowledgeDocs({ fields: ["root", "path", "title", "summary", "tags", "always", "writable"] })) as KnowledgeDoc[],
  });
}

export function useKnowledgeDoc(path: string | null) {
  return useQuery({
    queryKey: knowledgeKeys.doc(path ?? ""),
    queryFn: async () => (unwrap(await knowledgeRead({ fields: ["text"], input: { path: path! } })) as { text: string }).text,
    enabled: path !== null,
  });
}

function useKnowledgeWrite<TArgs, TResult>(fn: (args: TArgs) => Promise<TResult>) {
  const client = useQueryClient();
  return useMutation({ mutationFn: fn, onSuccess: () => void client.invalidateQueries({ queryKey: knowledgeKeys.all }) });
}

export function useKnowledgeActions() {
  return {
    write: useKnowledgeWrite(async ({ path, content }: { path: string; content: string }) => unwrap(await knowledgeWrite({ input: { path, content } }))),
    remove: useKnowledgeWrite(async (path: string) => unwrap(await knowledgeDelete({ input: { path } }))),
  };
}
