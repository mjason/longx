import { afterEach, beforeEach, expect, test, vi } from "vitest";

let send: ReturnType<typeof vi.fn>;
beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  document.body.innerHTML = `<form id="form">
    <input id="device-name"><button id="save-name" type="button">保存名称</button>
    <input id="server"><button id="connect">连接</button><button id="disconnect" type="button">断开</button>
    </form><p id="status"></p><p id="identity"></p><p id="hint"></p><section id="sessions"><ul></ul></section>`;
  send = vi.fn(async () => ({
    status: "disconnected", name: null, deviceName: "Chrome · macOS · 123abc",
    serverUrl: null, sessions: [], error: null,
  }));
  vi.stubGlobal("chrome", { runtime: { sendMessage: send } });
  await import("./popup");
  await Promise.resolve();
});

afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); });

test("generated names appear before connecting; status polling preserves an unsaved draft", async () => {
  const name = document.querySelector<HTMLInputElement>("#device-name")!;
  expect(name.value).toBe("Chrome · macOS · 123abc");
  name.value = "主力 Mac";
  name.dispatchEvent(new Event("input"));
  await vi.advanceTimersByTimeAsync(1000);
  expect(name.value).toBe("主力 Mac");
  const server = document.querySelector<HTMLInputElement>("#server")!;
  server.value = "https://longx.test";
  document.querySelector("#form")!.dispatchEvent(new Event("submit", { cancelable: true }));
  await Promise.resolve();
  expect(send).toHaveBeenCalledWith({ type: "connect", serverUrl: "https://longx.test", deviceName: "主力 Mac" });
});

test("saving a name works without registering a new browser", async () => {
  const name = document.querySelector<HTMLInputElement>("#device-name")!;
  name.value = "客厅 Mac";
  name.dispatchEvent(new Event("input"));
  document.querySelector<HTMLButtonElement>("#save-name")!.click();
  await Promise.resolve();
  expect(send).toHaveBeenCalledWith({ type: "rename", deviceName: "客厅 Mac" });
});

test("connect is disabled for empty or whitespace-only addresses", () => {
  const server = document.querySelector<HTMLInputElement>("#server")!;
  const button = document.querySelector<HTMLButtonElement>("#connect")!;
  expect(button.disabled).toBe(true);
  server.value = "https://longx.test";
  server.dispatchEvent(new Event("input"));
  expect(button.disabled).toBe(false);
  server.value = "   ";
  server.dispatchEvent(new Event("input"));
  expect(button.disabled).toBe(true);
  document.querySelector("#form")!.dispatchEvent(new Event("submit", { cancelable: true }));
  expect(send).not.toHaveBeenCalledWith(expect.objectContaining({ type: "connect" }));
});

test("a stored address enables connect, but polling does not refill a cleared draft", async () => {
  send.mockResolvedValue({
    status: "approved", name: "Mac", deviceName: "Mac",
    serverUrl: "https://longx.test", sessions: [], error: null,
  });
  await vi.advanceTimersByTimeAsync(1000);
  const server = document.querySelector<HTMLInputElement>("#server")!;
  const button = document.querySelector<HTMLButtonElement>("#connect")!;
  expect(server.value).toBe("https://longx.test");
  expect(button.disabled).toBe(false);
  server.value = "";
  server.dispatchEvent(new Event("input"));
  await vi.advanceTimersByTimeAsync(1000);
  expect(server.value).toBe("");
  expect(button.disabled).toBe(true);
});

test("editing and polling keep connect disabled while a request is pending", async () => {
  let resolveConnect!: (reply: unknown) => void;
  send.mockImplementation((message) => message.type === "connect"
    ? new Promise((resolve) => { resolveConnect = resolve; })
    : Promise.resolve({
      status: "disconnected", deviceName: "Mac", serverUrl: null, sessions: [], error: null,
    }));
  const server = document.querySelector<HTMLInputElement>("#server")!;
  const button = document.querySelector<HTMLButtonElement>("#connect")!;
  server.value = "https://longx.test";
  server.dispatchEvent(new Event("input"));
  document.querySelector("#form")!.dispatchEvent(new Event("submit", { cancelable: true }));
  server.value = "";
  server.dispatchEvent(new Event("input"));
  await vi.advanceTimersByTimeAsync(1000);
  expect(button.disabled).toBe(true);
  resolveConnect({ failed: "connection failed" });
  await vi.advanceTimersByTimeAsync(0);
  expect(button.disabled).toBe(true);
  server.value = "https://longx.test";
  server.dispatchEvent(new Event("input"));
  expect(button.disabled).toBe(false);
});
