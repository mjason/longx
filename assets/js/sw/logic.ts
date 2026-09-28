// The service worker's rules, pure (sw.ts carries them out): which request
// it answers and how, and which caches go when a new build takes over.

export type RequestKind =
  /** hashed files under /assets: immutable, from the cache first */
  | "asset"
  /** a page: from the network, the cached shell when the server is out of reach */
  | "navigate"
  /** icons and the manifest: from the cache, refreshed behind */
  | "static"
  /** not ours: the API, the sockets, downloads, callbacks — straight to the network */
  | "skip";

// what always goes to the server, even as a navigation (an API address opened in a tab, a download)
const NETWORK_ONLY = ["/phoenix/", "/gql", "/api/", "/socket", "/chrome/", "/files/", "/attachments/", "/hooks/", "/callback/", "/extension/", "/dev/", "/health", "/sw.js"];
const STATIC = /^\/(icons|images)\/|^\/(manifest\.webmanifest|favicon\.ico|favicon-32\.png)$/;

export function classify(url: URL, origin: string, method: string, mode: string, destination: string): RequestKind {
  if (method !== "GET" || url.origin !== origin) return "skip";
  if (NETWORK_ONLY.some((p) => url.pathname === p || url.pathname.startsWith(p))) return "skip";
  if (url.pathname.startsWith("/assets/")) return "asset";
  // the page itself only: a frame is a navigation too, and its answer is no shell
  if (mode === "navigate") return destination === "document" ? "navigate" : "skip";
  if (STATIC.test(url.pathname)) return "static";
  return "skip";
}

export const SHELL_CACHE = "longx-shell";
const ASSETS_PREFIX = "longx-assets-";

/** A build's cache; its version starts with the build time in base 36, so names sort by age. */
export function assetsCache(version: string): string {
  return ASSETS_PREFIX + version;
}

/** The caches to delete: every build's but the current one and the one before it. */
export function staleCaches(names: string[], current: string): string[] {
  const builds = names.filter((n) => n.startsWith(ASSETS_PREFIX) && n !== current).sort().reverse();
  return builds.slice(1);
}

/** The cached shell, marked as such: the page knows it is offline and reloads once the server is back (ui/pwa/PwaBridge). */
export function markOffline(html: string): string {
  return html.replace(/<html(\s|>)/, '<html data-offline-shell=""$1');
}
