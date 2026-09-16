// Lifecycle hooks wired into the generated client (config :ash_typescript):
// every call carries `transport.ts`'s headers — the page's CSRF token in the
// browser, the device's bearer in the native app — and, when a server is
// configured, goes to it instead of the page's origin.
import type { ActionConfig, ValidationConfig } from "@/ash_rpc";
import { authHeaders, transport, transportUrl } from "./transport";

export type ActionHookContext = Record<string, never>;
export type ValidationHookContext = Record<string, never>;

export { csrfToken } from "./transport";

function prepared<T extends { headers?: Record<string, string>; customFetch?: ActionConfig["customFetch"] }>(config: T): T {
  const next = { ...config, headers: { ...authHeaders(), ...config.headers } };
  if (transport().baseUrl && !config.customFetch) {
    next.customFetch = (input, init) => fetch(typeof input === "string" ? transportUrl(input) : input, init);
  }
  return next;
}

export async function beforeRequest(_action: string, config: ActionConfig): Promise<ActionConfig> {
  return prepared(config);
}

export async function beforeValidationRequest(
  _action: string,
  config: ValidationConfig,
): Promise<ValidationConfig> {
  return prepared(config);
}
