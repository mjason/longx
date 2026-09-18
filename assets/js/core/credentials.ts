// Credentials — the API keys and OAuth2 tokens Longx keeps for the agent
// (Longx.Credentials): listed without their values, created with them,
// logged in through the browser, refreshed by hand. DOM-free.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  createCredentialApiKey,
  createCredentialOauth2,
  credentialLoginUrl,
  credentialRedirectUri,
  deleteCredential,
  listCredentials,
  refreshCredential,
  updateCredential,
} from "@/ash_rpc";
import { unwrap } from "@/core/projects";

export type CredentialKind = "api_key" | "oauth2";
export type CredentialStatus = "ready" | "expired" | "needs_login" | "error";

export type Credential = {
  id: string;
  name: string;
  label: string | null;
  kind: CredentialKind;
  header: string;
  scheme: string;
  allowedHosts: string[];
  clientId: string | null;
  authorizeUrl: string | null;
  tokenUrl: string | null;
  registrationUrl: string | null;
  scopes: string | null;
  pkce: boolean;
  expiresAt: string | null;
  refreshedAt: string | null;
  lastError: string | null;
  status: CredentialStatus | null;
  hasSecret: boolean | null;
  hasAccessToken: boolean | null;
  hasRefreshToken: boolean | null;
  hasClientSecret: boolean | null;
};

export const credentialFields = [
  "id",
  "name",
  "label",
  "kind",
  "header",
  "scheme",
  "allowedHosts",
  "clientId",
  "authorizeUrl",
  "tokenUrl",
  "registrationUrl",
  "scopes",
  "pkce",
  "expiresAt",
  "refreshedAt",
  "lastError",
  "status",
  "hasSecret",
  "hasAccessToken",
  "hasRefreshToken",
  "hasClientSecret",
] as const;

export const credentialKeys = {
  all: ["credentials"] as const,
  redirect: (origin: string | null) => ["credentials", "redirect", origin] as const,
};

export type ApiKeyInput = {
  name: string;
  label?: string;
  allowedHosts: string[];
  header?: string;
  scheme?: string;
  secret: string;
};

export type Oauth2Input = {
  name: string;
  label?: string;
  allowedHosts: string[];
  header?: string;
  scheme?: string;
  authorizeUrl?: string;
  tokenUrl?: string;
  registrationUrl?: string;
  scopes?: string;
  clientId?: string;
  clientSecret?: string;
  pkce?: boolean;
};

export type CredentialUpdate = Partial<Omit<ApiKeyInput, "name"> & Omit<Oauth2Input, "name">>;

/** The hosts a person typed, one per line or comma: hostnames (a pasted URL keeps its host). */
export function splitHosts(text: string): string[] {
  return text
    .split(/[\n,;\s]+/)
    .map((h) => h.trim())
    .filter((h) => h.length > 0);
}

export function useCredentials(options: { refetchInterval?: number | false } = {}) {
  return useQuery({
    queryKey: credentialKeys.all,
    queryFn: async () => unwrap(await listCredentials({ fields: [...credentialFields] })) as Credential[],
    refetchInterval: options.refetchInterval ?? false,
  });
}

/** The redirect URI to register at an OAuth2 provider, for this browser's origin. */
export function useRedirectUri(origin: string | null) {
  return useQuery({
    queryKey: credentialKeys.redirect(origin),
    queryFn: async () =>
      unwrap(await credentialRedirectUri({ fields: ["uri"], input: origin ? { origin } : {} })).uri,
    staleTime: 5 * 60_000,
  });
}

export function useCredentialActions() {
  const client = useQueryClient();
  const invalidate = () => client.invalidateQueries({ queryKey: credentialKeys.all });
  const fields = [...credentialFields];
  const createApiKey = useMutation({
    mutationFn: async (input: ApiKeyInput) => unwrap(await createCredentialApiKey({ fields, input })) as Credential,
    onSuccess: invalidate,
  });
  const createOauth2 = useMutation({
    mutationFn: async (input: Oauth2Input) => unwrap(await createCredentialOauth2({ fields, input })) as Credential,
    onSuccess: invalidate,
  });
  const update = useMutation({
    mutationFn: async ({ id, input }: { id: string; input: CredentialUpdate }) =>
      unwrap(await updateCredential({ fields, identity: id, input })) as Credential,
    onSuccess: invalidate,
  });
  const remove = useMutation({
    mutationFn: async (id: string) => unwrap(await deleteCredential({ identity: id })),
    onSuccess: invalidate,
  });
  const loginUrl = useMutation({
    mutationFn: async ({ id, origin }: { id: string; origin: string | null }) =>
      unwrap(await credentialLoginUrl({ fields: ["url", "redirectUri"], input: origin ? { id, origin } : { id } })),
  });
  const refresh = useMutation({
    mutationFn: async (id: string) => unwrap(await refreshCredential({ fields, input: { id } })) as Credential,
    onSuccess: invalidate,
  });
  return { createApiKey, createOauth2, update, remove, loginUrl, refresh, invalidate };
}
