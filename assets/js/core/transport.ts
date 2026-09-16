// Where the server is and how a call proves who it is. The browser needs
// neither told: relative URLs on its own origin, the page's CSRF token. A
// native app (mobile/) configures the server it paired with and the device
// token (Longx.System.Device) it got, and everything — the RPC client
// (rpcHooks), the socket, uploads — follows. DOM-free: the CSRF meta is
// read only where a document exists.

export type Transport = {
  /** the server's origin (`http://host:port`); "" = the page's own */
  baseUrl: string;
  /** the paired device's bearer token; null in the browser */
  token: string | null;
};

const initial: Transport = { baseUrl: "", token: null };
let current: Transport = initial;

export function configureTransport(next: Partial<Transport>): void {
  current = { ...current, ...next, baseUrl: (next.baseUrl ?? current.baseUrl).replace(/\/+$/, "") };
}

export function resetTransport(): void {
  current = initial;
}

export function transport(): Transport {
  return current;
}

/** an absolute URL on the configured server, or the path itself in the browser */
export function transportUrl(path: string): string {
  return current.baseUrl ? current.baseUrl + path : path;
}

/** Phoenix's user socket */
export function socketUrl(): string {
  if (!current.baseUrl) return "/socket";
  return current.baseUrl.replace(/^http/, "ws") + "/socket";
}

export function csrfToken(doc: Document | undefined = globalThis.document): string | null {
  return doc?.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? null;
}

/** the headers every call carries: the bearer when paired, else the page's CSRF token */
export function authHeaders(): Record<string, string> {
  if (current.token) return { Authorization: `Bearer ${current.token}` };
  const token = csrfToken();
  return token ? { "X-CSRF-Token": token } : {};
}
