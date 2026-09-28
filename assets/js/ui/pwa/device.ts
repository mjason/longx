// The browser's PWA APIs, each behind what it needs: a secure context (HTTPS
// or localhost — a LAN's plain http gets none of them) and the API itself.
// Every call is safe where the API is missing.
import type { NotificationSpec } from "@/core/notify";

const secure = () => typeof window !== "undefined" && window.isSecureContext === true;

export function offlineCacheSupported(): boolean {
  return secure() && "serviceWorker" in navigator;
}

export function notificationsSupported(): boolean {
  return secure() && typeof Notification !== "undefined";
}

export function badgeSupported(): boolean {
  return secure() && typeof (navigator as Navigator & { setAppBadge?: unknown }).setAppBadge === "function";
}

export function notificationPermission(): NotificationPermission | "unsupported" {
  return notificationsSupported() ? Notification.permission : "unsupported";
}

export async function requestNotifications(): Promise<NotificationPermission | "unsupported"> {
  if (!notificationsSupported()) return "unsupported";
  return Notification.requestPermission();
}

/**
 * The service worker in step with the device's choice: registered when on
 * (a production build only — in dev every file changes all the time), else
 * unregistered with its caches gone.
 */
export async function syncServiceWorker(on: boolean, prod: boolean): Promise<"registered" | "unregistered" | "unsupported"> {
  if (!offlineCacheSupported()) return "unsupported";
  const container = navigator.serviceWorker;
  if (on && prod) {
    await container.register("/sw.js", { scope: "/", updateViaCache: "none" });
    return "registered";
  }
  const registrations = await container.getRegistrations();
  await Promise.all(registrations.map((r) => r.unregister()));
  if (typeof caches !== "undefined") {
    const names = await caches.keys();
    await Promise.all(names.filter((n) => n.startsWith("longx-")).map((n) => caches.delete(n)));
  }
  return "unregistered";
}

/**
 * A system notification: through the service worker when one controls the
 * page (its click focuses the app, installed or not), else the page's own,
 * whose click comes back here.
 */
export async function showSystemNotification(spec: NotificationSpec, onClick: (url: string) => void): Promise<void> {
  if (notificationPermission() !== "granted") return;
  if (offlineCacheSupported() && navigator.serviceWorker.controller) {
    const registration = await navigator.serviceWorker.ready;
    await registration.showNotification(spec.title, spec.options);
    return;
  }
  const notification = new Notification(spec.title, spec.options);
  notification.onclick = () => {
    notification.close();
    onClick(spec.options.data.url);
  };
}

/** The app icon's badge (an installed app): the count, or none at 0. */
export function setBadge(count: number): void {
  if (!badgeSupported()) return;
  const nav = navigator as Navigator & { setAppBadge(n?: number): Promise<void>; clearAppBadge(): Promise<void> };
  void (count > 0 ? nav.setAppBadge(count) : nav.clearAppBadge()).catch(() => undefined);
}

/** Whether this page is the service worker's cached shell (the server was out of reach when it loaded). */
export function offlineShell(): boolean {
  return document.documentElement.hasAttribute("data-offline-shell");
}

/** Asks the server every `everyMs` until it answers, then `onBack()` once; returns the function that stops asking. */
export function whenServerBack(onBack: () => void, everyMs = 5_000, get: typeof fetch = fetch): () => void {
  let stopped = false;
  const timer = setInterval(() => {
    void get("/health", { cache: "no-store" }).then(
      (response) => {
        if (!response.ok || stopped) return;
        stopped = true;
        clearInterval(timer);
        onBack();
      },
      () => undefined,
    );
  }, everyMs);
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}
