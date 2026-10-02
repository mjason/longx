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
