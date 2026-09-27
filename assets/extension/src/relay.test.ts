import { describe, expect, test, vi } from "vitest";
import { Bridge, handleCommand, installEventForwarders, type ChannelLike } from "./relay";

// a chrome.* event: listeners added, removed and fired by the test
function event() {
  const set = new Set<(...args: unknown[]) => void>();
  return {
    set,
    addListener: (fn: (...args: unknown[]) => void) => void set.add(fn),
    removeListener: (fn: (...args: unknown[]) => void) => void set.delete(fn),
    fire: (...args: unknown[]) => set.forEach((fn) => fn(...args)),
  };
}

function fakeChrome() {
  return {
    debugger: {
      attach: vi.fn(async () => undefined),
      detach: vi.fn(async () => undefined),
      sendCommand: vi.fn(async (_target: unknown, method: string) => ({ ran: method })),
      onEvent: event(),
      onDetach: event(),
    },
    tabs: {
      create: vi.fn(async (props: object) => ({ id: 7, ...props })),
      query: vi.fn(async () => [{ id: 7 }]),
      remove: vi.fn(async () => {
        throw new Error("No tab with id: 99.");
      }),
      onCreated: event(),
      onUpdated: event(),
      onRemoved: event(),
    },
    tabGroups: { update: vi.fn(async () => ({ id: 3 })), onRemoved: event() },
    windows: { update: vi.fn(async () => ({ id: 1 })) },
    runtime: { reload: vi.fn() },
  };
}

function fakeChannel() {
  const handlers: Record<string, (payload?: unknown) => void> = {};
  const replies: Record<string, (response?: unknown) => void> = {};
  const pushes: { event: string; payload: unknown }[] = [];
  const receive = {
    receive(status: string, cb: (response?: unknown) => void) {
      replies[status] = cb;
      return receive;
    },
  };
  const channel: ChannelLike = {
    on: (name, cb) => void (handlers[name] = cb),
    push: (name, payload) => void pushes.push({ event: name, payload }),
    join: () => receive,
  };
  return { channel, handlers, replies, pushes, fire: (name: string, payload?: unknown) => handlers[name]?.(payload) };
}

function fakeStorage(initial: Record<string, unknown> = {}) {
  const data: Record<string, unknown> = { ...initial };
  return {
    data,
    set: async (items: Record<string, unknown>) => void Object.assign(data, items),
    remove: async (keys: string | string[]) => {
      for (const k of Array.isArray(keys) ? keys : [keys]) delete data[k];
    },
  };
}

function bridge(opts: { token?: string } = {}) {
  const chromeApi = fakeChrome();
  const ch = fakeChannel();
  const storage = fakeStorage(opts.token ? { token: opts.token } : {});
  const host = { reconnect: vi.fn(), disconnect: vi.fn(), changed: vi.fn() };
  const b = new Bridge({ chrome: chromeApi, channel: ch.channel, storage, host, token: opts.token ?? null });
  b.start();
  return { b, chromeApi, ch, storage, host };
}

describe("handleCommand", () => {
  test("an allow-listed method runs on its namespace with the positional params", async () => {
    const c = fakeChrome();
    expect(await handleCommand(c, "chrome.tabs.create", [{ url: "about:blank", active: false }])).toEqual({
      id: 7,
      url: "about:blank",
      active: false,
    });
    expect(c.tabs.create).toHaveBeenCalledWith({ url: "about:blank", active: false });
    expect(c.tabs.create.mock.contexts[0]).toBe(c.tabs);
    expect(await handleCommand(c, "chrome.debugger.sendCommand", [{ tabId: 12 }, "Page.navigate", { url: "x" }])).toEqual({
      ran: "Page.navigate",
    });
    expect(c.debugger.sendCommand).toHaveBeenCalledWith({ tabId: 12 }, "Page.navigate", { url: "x" });
  });

  test("anything off the allow-list is refused, whether chrome has it or not", async () => {
    const c = fakeChrome();
    await expect(handleCommand(c, "chrome.runtime.reload", [])).rejects.toThrow("Unknown method: chrome.runtime.reload");
    await expect(handleCommand(c, "chrome.tabs.executeScript", [])).rejects.toThrow("Unknown method: chrome.tabs.executeScript");
    await expect(handleCommand(c, "eval", ["1"])).rejects.toThrow("Unknown method: eval");
    expect(c.runtime.reload).not.toHaveBeenCalled();
  });

  test("an allow-listed method this Chrome lacks says so", async () => {
    const c = fakeChrome() as unknown as { tabGroups?: unknown };
    delete c.tabGroups;
    await expect(handleCommand(c, "chrome.tabGroups.update", [3, {}])).rejects.toThrow("chrome.tabGroups.update is not available");
  });
});

describe("Bridge commands", () => {
  test("a cmd is answered as a result with the same id; a void result is {}; a throw is its message", async () => {
    const { ch } = bridge();
    ch.replies.ok?.({ browser_id: "b1", status: "approved", name: "Chrome" });

    ch.fire("cmd", { id: "k1", method: "chrome.debugger.sendCommand", params: [{ tabId: 12 }, "Page.enable", {}] });
    ch.fire("cmd", { id: "k2", method: "chrome.debugger.attach", params: [{ tabId: 12 }, "1.3"] });
    ch.fire("cmd", { id: "k3", method: "chrome.tabs.remove", params: [99] });
    ch.fire("cmd", { id: "k4", method: "chrome.scripting.executeScript", params: [{}] });

    await vi.waitFor(() => expect(ch.pushes).toHaveLength(4));
    const results = ch.pushes.filter((p) => p.event === "result").map((p) => p.payload);
    expect(results).toContainEqual({ id: "k1", result: { ran: "Page.enable" } });
    expect(results).toContainEqual({ id: "k2", result: {} });
    expect(results).toContainEqual({ id: "k3", error: "No tab with id: 99." });
    expect(results).toContainEqual({ id: "k4", error: "Unknown method: chrome.scripting.executeScript" });
  });
});

describe("installEventForwarders", () => {
  test("the six events go out in their documented shapes, padded to their arity; uninstall removes the listeners", () => {
    const c = fakeChrome();
    const send = vi.fn();
    const uninstall = installEventForwarders(c, send);

    c.debugger.onEvent.fire({ tabId: 12 }, "Runtime.consoleAPICalled", { type: "log" });
    c.debugger.onEvent.fire({ tabId: 12 }, "Runtime.executionContextsCleared");
    c.debugger.onDetach.fire({ tabId: 12 }, "target_closed");
    c.tabs.onCreated.fire({ id: 13, url: "about:blank" });
    c.tabs.onUpdated.fire(13, { status: "complete" }, { id: 13, url: "https://x" });
    c.tabs.onRemoved.fire(13, { windowId: 1, isWindowClosing: false });
    c.tabGroups.onRemoved.fire({ id: 3, title: "Longx" });

    expect(send.mock.calls).toEqual([
      ["chrome.debugger.onEvent", [{ tabId: 12 }, "Runtime.consoleAPICalled", { type: "log" }]],
      ["chrome.debugger.onEvent", [{ tabId: 12 }, "Runtime.executionContextsCleared", null]],
      ["chrome.debugger.onDetach", [{ tabId: 12 }, "target_closed"]],
      ["chrome.tabs.onCreated", [{ id: 13, url: "about:blank" }]],
      ["chrome.tabs.onUpdated", [13, { status: "complete" }, { id: 13, url: "https://x" }]],
      ["chrome.tabs.onRemoved", [13, { windowId: 1, isWindowClosing: false }]],
      ["chrome.tabGroups.onRemoved", [{ id: 3, title: "Longx" }]],
    ]);

    uninstall();
    c.tabs.onRemoved.fire(14, {});
    expect(send).toHaveBeenCalledTimes(7);
    expect(c.debugger.onEvent.set.size).toBe(0);
  });

  test("the bridge pushes an event only once joined", () => {
    const { b, ch } = bridge();
    b.sendEvent("chrome.tabs.onRemoved", [1, {}]);
    expect(ch.pushes).toEqual([]);
    ch.replies.ok?.({ browser_id: "b1", status: "pending", name: "Chrome" });
    b.sendEvent("chrome.tabs.onRemoved", [1, {}]);
    expect(ch.pushes).toEqual([{ event: "event", payload: { method: "chrome.tabs.onRemoved", params: [1, {}] } }]);
  });
});

describe("Bridge pairing", () => {
  test("pending until the person allows it; the approved push stores the token and the name", async () => {
    const { b, ch, storage, host } = bridge();
    expect(b.status).toBe("connecting");
    ch.replies.ok?.({ browser_id: "b1", status: "pending", name: "Chrome 153 · Linux" });
    expect(b.status).toBe("pending");
    expect(b.name).toBe("Chrome 153 · Linux");

    ch.fire("approved", { token: "tok-1", name: "QA Chrome" });
    await vi.waitFor(() => expect(storage.data.token).toBe("tok-1"));
    expect(b.status).toBe("approved");
    expect(b.name).toBe("QA Chrome");
    // the socket's params closure reads this: a rejoin after a network blip carries the token
    expect(b.token).toBe("tok-1");
    ch.replies.ok?.({ browser_id: "b1", status: "approved", name: "QA Chrome" });
    expect(b.status).toBe("approved");
    expect(storage.data).toMatchObject({ status: "approved", name: "QA Chrome" });
    expect(host.changed).toHaveBeenCalled();
    expect(host.reconnect).not.toHaveBeenCalled();

    ch.fire("state", { sessions: [{ title: "fix the login page", tabs: 2 }] });
    expect(b.sessions).toEqual([{ title: "fix the login page", tabs: 2 }]);
  });

  test("a token the server refuses is forgotten and the host asked for a fresh socket without it", async () => {
    const { b, ch, storage, host } = bridge({ token: "stale" });
    ch.replies.ok?.({ status: "bad_token" });
    await vi.waitFor(() => expect(host.reconnect).toHaveBeenCalled());
    expect(storage.data.token).toBeUndefined();
    expect(b.token).toBeNull();
    expect(b.status).toBe("bad_token");
    expect(host.disconnect).not.toHaveBeenCalled();
  });

  test("bad_token with no token sent cannot be fixed by reconnecting: the host is told to stop", async () => {
    // the row is approved on the server but this install lost its token —
    // reconnecting every alarm tick would only repeat the refusal
    const { b, ch, host } = bridge();
    ch.replies.ok?.({ status: "bad_token" });
    await vi.waitFor(() => expect(host.disconnect).toHaveBeenCalled());
    expect(host.reconnect).not.toHaveBeenCalled();
    expect(b.status).toBe("bad_token");
  });

  test("revoked forgets the token and disconnects", async () => {
    const { b, ch, storage, host } = bridge({ token: "tok-1" });
    ch.replies.ok?.({ browser_id: "b1", status: "approved", name: "QA Chrome" });
    expect(b.status).toBe("approved");
    ch.fire("revoked", {});
    await vi.waitFor(() => expect(host.disconnect).toHaveBeenCalled());
    expect(storage.data.token).toBeUndefined();
    expect(b.token).toBeNull();
    expect(b.status).toBe("revoked");
    expect(storage.data.status).toBe("revoked");
  });

  test("a join the server refuses or never answers is an error with the reason", () => {
    const a = bridge();
    a.ch.replies.error?.({ reason: "install_id and device are needed" });
    expect(a.b.status).toBe("error");
    expect(a.b.error).toBe("install_id and device are needed");
    const t = bridge();
    t.ch.replies.timeout?.();
    expect(t.b.status).toBe("error");
    expect(t.b.error).toMatch(/timed out/);
  });
});
