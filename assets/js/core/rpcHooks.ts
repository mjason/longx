// Lifecycle hooks wired into the generated client (config :ash_typescript).
// The one cross-cutting concern today: Phoenix's CSRF token on every RPC
// call from the browser. A native client will add its bearer token here.
import type { ActionConfig, ValidationConfig } from "@/ash_rpc";

export type ActionHookContext = Record<string, never>;
export type ValidationHookContext = Record<string, never>;

export function csrfToken(doc: Document | undefined = globalThis.document): string | null {
  return doc?.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? null;
}

function withCsrf<T extends { headers?: Record<string, string> }>(config: T): T {
  const token = csrfToken();
  if (!token) return config;
  return { ...config, headers: { ...config.headers, "X-CSRF-Token": token } };
}

export async function beforeRequest(_action: string, config: ActionConfig): Promise<ActionConfig> {
  return withCsrf(config);
}

export async function beforeValidationRequest(
  _action: string,
  config: ValidationConfig,
): Promise<ValidationConfig> {
  return withCsrf(config);
}
