// The PWA on a secure context (127.0.0.1 counts as one): the service worker
// registers a few seconds after load and takes the page; it holds the app's
// files and the shell. Offline, a reload still draws the page — marked as
// the cached shell, saying so — and it reloads by itself once the server is
// back. With 系统通知 on, a turn finishing while the page is out of focus
// raises a system notification (through the worker); the notify join sets
// the app's badge.
import { chromium } from "playwright";
import { BASE, expect, sleep } from "../lib.mjs";

async function until(what, fn, ms = 15_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await fn().catch(() => false)) return;
    await sleep(250);
  }
  expect(false, what);
}

// records what the page asks of the notification and badge APIs, still calling through
const INSTRUMENT = () => {
  window.__notes = [];
  window.__badges = [];
  const show = ServiceWorkerRegistration.prototype.showNotification;
  ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
    window.__notes.push({ via: "worker", title, tag: options?.tag, url: options?.data?.url });
    return show.call(this, title, options);
  };
  const set = navigator.setAppBadge?.bind(navigator);
  const clear = navigator.clearAppBadge?.bind(navigator);
  navigator.setAppBadge = (n) => (window.__badges.push(n), set ? set(n).catch(() => {}) : Promise.resolve());
  navigator.clearAppBadge = () => (window.__badges.push(0), clear ? clear().catch(() => {}) : Promise.resolve());
};

export async function run(h) {
  expect(/^http:\/\/(127\.0\.0\.1|localhost)|^https:/.test(BASE), `the PWA needs a secure context: ${BASE}`);
  // Chromium's new headless mode: the old headless shell answers every
  // notification permission "denied", granted or not
  const browser = await chromium.launch({ channel: "chromium" });
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    await context.grantPermissions(["notifications"], { origin: BASE });
    await context.addInitScript(INSTRUMENT);
    const page = await h.watch(await context.newPage());
    await h.open(page, "/");
    await pwa(h, context, page);
  } finally {
    await browser.close();
  }
}

async function pwa(h, context, page) {
  // the worker: registered after load, active, controlling the page after a reload
  await until("the service worker is active", () => page.evaluate(async () => (await navigator.serviceWorker.getRegistration())?.active?.state === "activated"), 30_000);
  await page.reload({ waitUntil: "networkidle" });
  expect(await page.evaluate(() => navigator.serviceWorker.controller !== null), "the worker controls the page after a reload");
  const caches = await page.evaluate(async () => {
    const names = await caches.keys();
    const assets = names.find((n) => n.startsWith("longx-assets-"));
    return { names, assets: assets ? (await (await caches.open(assets)).keys()).length : 0, shell: names.includes("longx-shell") };
  });
  expect(caches.assets > 100, `the app's files are cached ahead of time: ${JSON.stringify(caches)}`);
  expect(caches.shell, `the shell is cached: ${JSON.stringify(caches.names)}`);

  // offline: the cached shell, marked, saying so; back online it reloads by itself
  const quiet = h.problems.length;
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  await until("the offline shell is marked", () => page.evaluate(() => document.documentElement.hasAttribute("data-offline-shell")));
  await page.getByTestId("connection-banner").filter({ hasText: "服务器暂时连不上" }).waitFor({ timeout: 10_000 });
  await page.locator("#app *").first().waitFor({ timeout: 10_000 });
  await h.shot(page, "offline");
  await context.setOffline(false);
  await until("back online, the page reloads from the server", () => page.evaluate(() => !document.documentElement.hasAttribute("data-offline-shell")), 20_000);
  // what failed while offline is the point of the check, not a problem
  h.problems.splice(quiet);

  // notifications on (this device), the page out of focus: a finished turn raises one
  await page.evaluate(() => localStorage.setItem("longx:notifications", "on"));
  await h.project();
  const thread = await h.thread();
  await h.open(page, `/p/${h.slug}/t/${thread.id}`);
  await until("the notify join sets the badge", () => page.evaluate(() => window.__badges.length > 0));
  await page.evaluate(() => Object.defineProperty(document, "hasFocus", { configurable: true, value: () => false }));
  await h.send(thread.id, "Reply with the single word: ok");
  await h.idle(thread.id);
  await until("a system notification for the finished turn", () => page.evaluate(() => window.__notes.length > 0), 20_000);
  const [note] = await page.evaluate(() => window.__notes);
  expect(note.via === "worker", `shown through the worker: ${JSON.stringify(note)}`);
  expect(note.tag.endsWith(":turn_completed") && note.url.includes(`/p/${h.slug}/t/`), `the notification names its conversation: ${JSON.stringify(note)}`);
  const shown = await page.evaluate(async () => (await (await navigator.serviceWorker.ready).getNotifications()).map((n) => n.title));
  expect(shown.length > 0, "the browser holds the notification");

  // 外观 shows the device's switches on
  await h.open(page, "/settings/appearance");
  expect(await page.getByRole("switch", { name: "系统通知" }).isChecked(), "系统通知 is on");
  expect(await page.getByRole("switch", { name: "离线缓存" }).isChecked(), "离线缓存 is on");
  await h.shot(page, "appearance");
}
