import { act, cleanup, render, waitFor } from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import * as api from "@/core/api";
import { setPreference } from "@/core/keys/preference";
import { channel, ok } from "@/ui/test-mocks";
import { whenServerBack } from "./device";
import { PwaBridge } from "./PwaBridge";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

const worker = {
  register: vi.fn(async () => ({})),
  getRegistrations: vi.fn(async () => [{ unregister: vi.fn(async () => true) }]),
  controller: null as object | null,
  ready: Promise.resolve({ showNotification: vi.fn(async () => undefined) }),
  listeners: {} as Record<string, (e: MessageEvent) => void>,
  addEventListener: vi.fn((type: string, cb: (e: MessageEvent) => void) => {
    worker.listeners[type] = cb;
  }),
  removeEventListener: vi.fn(),
};
const shown: { title: string; options: NotificationOptions }[] = [];
class FakeNotification {
  static permission: NotificationPermission = "granted";
  static requestPermission = vi.fn(async () => "granted" as NotificationPermission);
  onclick: (() => void) | null = null;
  constructor(title: string, options: NotificationOptions) {
    shown.push({ title, options });
  }
  close() {}
}
const setAppBadge = vi.fn(async () => undefined);
const clearAppBadge = vi.fn(async () => undefined);

function mount(prod = true) {
  const router = createMemoryRouter([{ path: "*", element: <PwaBridge prod={prod} registerAfterMs={0} /> }], { initialEntries: ["/"] });
  render(<RouterProvider router={router} />);
  return router;
}

beforeEach(() => {
  Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: worker });
  Object.assign(navigator, { setAppBadge, clearAppBadge });
  vi.stubGlobal("Notification", FakeNotification);
  vi.stubGlobal("caches", { keys: vi.fn(async () => ["longx-assets-1", "other"]), delete: vi.fn(async () => true) });
  channel.reset();
  shown.length = 0;
  vi.clearAllMocks();
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  localStorage.clear();
  Object.defineProperty(window, "isSecureContext", { configurable: true, value: false });
  delete (navigator as { serviceWorker?: unknown }).serviceWorker;
  delete (navigator as { setAppBadge?: unknown }).setAppBadge;
  delete (navigator as { clearAppBadge?: unknown }).clearAppBadge;
});

describe("the page's half of the PWA", () => {
  test("the service worker follows the device's choice: registered at /sw.js, removed with Longx's caches when off", async () => {
    mount();
    await waitFor(() => expect(worker.register).toHaveBeenCalledWith("/sw.js", { scope: "/", updateViaCache: "none" }));

    act(() => setPreference("offlineCache", false));
    await waitFor(() => expect(worker.getRegistrations).toHaveBeenCalled());
    await waitFor(() => expect(caches.delete).toHaveBeenCalledWith("longx-assets-1"));
    expect(caches.delete).not.toHaveBeenCalledWith("other");
  });

  test("a development build never registers it", async () => {
    mount(false);
    await waitFor(() => expect(worker.getRegistrations).toHaveBeenCalled());
    expect(worker.register).not.toHaveBeenCalled();
  });

  test("a notification's click (through the worker) moves the page to its conversation", async () => {
    const router = mount();
    await waitFor(() => expect(worker.listeners["message"]).toBeDefined());
    act(() => worker.listeners["message"]!(new MessageEvent("message", { data: { type: "longx:navigate", url: "/p/math/t/th1" } })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/math/t/th1"));
  });

  test("with notifications on, an event while the page is out of focus raises one; the badge counts what waits", async () => {
    setPreference("notifications", true);
    vi.spyOn(document, "hasFocus").mockReturnValue(false);
    const router = mount();
    await waitFor(() => expect(channel.byTopic["notify"]).toBeDefined());

    act(() => channel.replyTo("notify", "ok", { running: [{ waiting: true }, { waiting: true }, { waiting: false }] }));
    expect(setAppBadge).toHaveBeenCalledWith(2);

    vi.mocked(api.listRunningThreads).mockResolvedValueOnce(ok({ threads: [] }) as never);
    act(() =>
      channel.deliverTo("notify", "event", {
        kind: "approval",
        title: "数学精灵 · 等你确认",
        body: "登录 COROS",
        url: "/p/math/t/th1",
        project_id: "p1",
        thread_id: "th1",
        at: "2026-09-28T01:00:00Z",
      }),
    );
    await waitFor(() => expect(shown).toHaveLength(1));
    expect(shown[0]).toMatchObject({ title: "数学精灵 · 等你确认", options: { body: "登录 COROS", tag: "th1:approval" } });
    await waitFor(() => expect(clearAppBadge).toHaveBeenCalled());
    expect(router.state.location.pathname).toBe("/");
  });

  test("notifications off: no notification, the badge still counts", async () => {
    mount();
    await waitFor(() => expect(channel.byTopic["notify"]).toBeDefined());
    act(() => channel.deliverTo("notify", "event", { kind: "turn_completed", title: "x", body: "y", url: "/", project_id: null, thread_id: null, at: "" }));
    expect(shown).toHaveLength(0);
  });

  test("the offline shell asks the server until it answers, then reloads once", async () => {
    vi.useFakeTimers();
    try {
      const get = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValue({ ok: true });
      const back = vi.fn();
      whenServerBack(back, 1000, get as never);
      await vi.advanceTimersByTimeAsync(1000);
      expect(back).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1000);
      await vi.advanceTimersByTimeAsync(3000);
      expect(back).toHaveBeenCalledTimes(1);
      expect(get).toHaveBeenCalledWith("/health", { cache: "no-store" });
    } finally {
      vi.useRealTimers();
    }
  });
});
