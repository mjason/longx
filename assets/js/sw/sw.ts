// Longx's service worker (built by js/build/plugins.ts `serviceWorker()`
// into priv/static/sw.js, registered only over HTTPS or on localhost). It
// makes the page load from this device: the app's files are fetched into
// the cache in the background right after install — so the first file,
// diff or card after an upgrade opens at once —, every hashed file is
// served from the cache first (they never change), a page comes from the
// network and, when the server is out of reach, from the last shell. The
// API, the sockets, downloads and callbacks never pass through it.
// A notification's click brings the page forward and opens its address.
import { assetsCache, classify, markOffline, SHELL_CACHE, staleCaches } from "./logic";

declare const __PRECACHE__: string[];
declare const __VERSION__: string;

type ExtendableEvent = Event & { waitUntil(promise: Promise<unknown>): void };
type FetchEvent = ExtendableEvent & { request: Request; respondWith(response: Promise<Response>): void };
type NotificationClick = ExtendableEvent & { notification: { close(): void; data?: { url?: string } } };
type WindowClient = { url: string; focus(): Promise<unknown>; postMessage(message: unknown): void };
type Worker = {
  addEventListener(type: string, listener: (event: never) => void): void;
  skipWaiting(): Promise<void>;
  location: Location;
  clients: {
    claim(): Promise<void>;
    matchAll(options: { type: "window"; includeUncontrolled: boolean }): Promise<WindowClient[]>;
    openWindow(url: string): Promise<unknown>;
  };
};

const sw = self as unknown as Worker;
const ASSETS = assetsCache(__VERSION__);

sw.addEventListener("install", (event: ExtendableEvent) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(ASSETS);
      // one by one: a file that is gone (an older build's) must not fail the rest
      await Promise.all(__PRECACHE__.map((url) => cache.add(url).catch(() => undefined)));
      // the shell, for a load while the server is out of reach
      await (await caches.open(SHELL_CACHE)).add("/").catch(() => undefined);
      await sw.skipWaiting();
    })(),
  );
});

sw.addEventListener("activate", (event: ExtendableEvent) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(staleCaches(names, ASSETS).map((name) => caches.delete(name)));
      await sw.clients.claim();
    })(),
  );
});

sw.addEventListener("fetch", (event: FetchEvent) => {
  const request = event.request;
  const kind = classify(new URL(request.url), sw.location.origin, request.method, request.mode, request.destination);
  if (kind === "asset") event.respondWith(cacheFirst(request, event));
  else if (kind === "navigate") event.respondWith(networkFirst(request, event));
  else if (kind === "static") event.respondWith(staleWhileRevalidate(request));
});

// the page gets the response as it streams in; the copy is written beside it
function keep(event: ExtendableEvent, cacheName: string, key: Request | string, response: Response): void {
  const copy = response.clone();
  event.waitUntil(caches.open(cacheName).then((cache) => cache.put(key, copy)).catch(() => undefined));
}

async function cacheFirst(request: Request, event: ExtendableEvent): Promise<Response> {
  const hit = await caches.match(request);
  if (hit) return hit;
  const response = await fetch(request);
  if (response.ok) keep(event, ASSETS, request, response);
  return response;
}

async function networkFirst(request: Request, event: ExtendableEvent): Promise<Response> {
  try {
    const response = await fetch(request);
    // every address is the same shell (the router draws the page): one copy is enough
    if (response.ok && (response.headers.get("content-type") ?? "").includes("text/html")) keep(event, SHELL_CACHE, "/", response);
    return response;
  } catch (error) {
    const shell = await caches.match("/", { cacheName: SHELL_CACHE });
    if (!shell) throw error;
    return new Response(markOffline(await shell.text()), { status: 200, headers: shell.headers });
  }
}

async function staleWhileRevalidate(request: Request): Promise<Response> {
  const cache = await caches.open(ASSETS);
  const hit = await cache.match(request);
  const refresh = fetch(request).then(
    async (response) => {
      if (response.ok) await cache.put(request, response.clone());
      return response;
    },
    () => hit ?? Response.error(),
  );
  return hit ?? refresh;
}

sw.addEventListener("notificationclick", (event: NotificationClick) => {
  event.notification.close();
  const url = event.notification.data?.url ?? "/";
  event.waitUntil(
    (async () => {
      const windows = await sw.clients.matchAll({ type: "window", includeUncontrolled: true });
      const open = windows.find((w) => new URL(w.url).origin === sw.location.origin);
      if (open) {
        await open.focus();
        open.postMessage({ type: "longx:navigate", url });
      } else {
        await sw.clients.openWindow(url);
      }
    })(),
  );
});
