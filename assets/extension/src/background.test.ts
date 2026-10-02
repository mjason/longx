import { beforeEach, expect, test, vi } from "vitest";
import type { PopupMessage, PopupReply } from "./messages";

const mocks = vi.hoisted(() => ({
  sockets: [] as { url: string; options: { params: () => { device: { name: string; name_revision: number } } }; connect: ReturnType<typeof vi.fn>; disconnect: ReturnType<typeof vi.fn> }[],
}));

vi.mock("phoenix", () => ({
  Socket: class {
    connect = vi.fn();
    disconnect = vi.fn();
    constructor(public url: string, public options: { params: () => { device: { name: string; name_revision: number } } }) { mocks.sockets.push(this); }
    connectionState() { return "open"; }
    onError() {}
    onClose() {}
    channel() {
      const receive = { receive: () => receive };
      return { on: vi.fn(), push: vi.fn(), join: () => receive };
    }
  },
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

let send: (message: PopupMessage) => Promise<PopupReply>;
let data: Record<string, unknown>;
let platform: ReturnType<typeof deferred<{ os: string }>>;

beforeEach(async () => {
  vi.resetModules();
  mocks.sockets.length = 0;
  data = { installId: "device-1", deviceName: "Initial Chrome", nameRevision: 0, serverUrl: "https://old.test", enabled: true, token: "old-token" };
  platform = deferred();
  const api = {
    storage: { local: {
      get: vi.fn(async () => ({ ...data })),
      set: vi.fn(async (values: object) => { Object.assign(data, values); }),
      remove: vi.fn(async (keys: string | string[]) => {
        for (const key of Array.isArray(keys) ? keys : [keys]) delete data[key];
      }),
    } },
    alarms: { get: vi.fn(async () => ({})), create: vi.fn(), onAlarm: { addListener: vi.fn() } },
    runtime: {
      onInstalled: { addListener: vi.fn() },
      onStartup: { addListener: vi.fn() },
      onMessage: { addListener: vi.fn((handler) => {
        send = (message) => new Promise((resolve) => handler(message, {}, resolve));
      }) },
      getPlatformInfo: vi.fn(() => platform.promise),
      getManifest: () => ({ version: "0.1.0" }),
    },
  };
  vi.stubGlobal("chrome", api);
  await import("./background");
  await vi.waitFor(() => expect(api.runtime.getPlatformInfo).toHaveBeenCalled());
});

test("reconnecting during an old device read never opens the old server", async () => {
  const reconnect = send({ type: "connect", serverUrl: "https://new.test" });
  await vi.waitFor(() => expect(data.serverUrl).toBe("https://new.test"));
  platform.resolve({ os: "mac" });
  await reconnect;
  await vi.waitFor(() => expect(mocks.sockets).toHaveLength(1));
  expect(mocks.sockets[0]?.url).toContain("new.test");
  expect(data.token).toBeUndefined();
});

test("disconnect during an in-flight connection cannot resurrect the socket", async () => {
  await send({ type: "disconnect" });
  platform.resolve({ os: "mac" });
  await send({ type: "status" });
  await vi.waitFor(() => expect(data.enabled).toBe(false));
  expect(mocks.sockets).toHaveLength(0);
});

test("editing a device name reconnects with the same identity and a persistent revision", async () => {
  platform.resolve({ os: "mac" });
  await vi.waitFor(() => expect(mocks.sockets).toHaveLength(1));
  const reply = await send({ type: "rename", deviceName: "  桌面 Mac  " });
  expect(reply).toMatchObject({ deviceName: "桌面 Mac" });
  await vi.waitFor(() => expect(mocks.sockets).toHaveLength(2));
  expect(mocks.sockets[1]?.options.params().device).toMatchObject({ name: "桌面 Mac", name_revision: 1 });
  expect(data.installId).toBe("device-1");
  await send({ type: "connect", serverUrl: "https://old.test" });
  expect(data.deviceName).toBe("桌面 Mac");
  expect(data.nameRevision).toBe(1);
  expect(data.token).toBe("old-token");
});

test("invalid names do not tear down a connection or alter the stored identity", async () => {
  const reply = await send({ type: "rename", deviceName: " " });
  expect(reply).toHaveProperty("failed");
  expect(data.deviceName).toBe("Initial Chrome");
  expect(data.nameRevision).toBe(0);
  platform.resolve({ os: "mac" });
});
