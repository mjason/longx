import { describe, expect, test } from "vitest";
import { normalizeServerUrl, socketUrl } from "./urls";

describe("normalizeServerUrl", () => {
  test("keeps origin and path prefix, drops a trailing slash, query and hash", () => {
    expect(normalizeServerUrl("  http://192.168.2.70:7788/ ")).toBe("http://192.168.2.70:7788");
    expect(normalizeServerUrl("https://longx.example.com/longx/?x=1#y")).toBe("https://longx.example.com/longx");
  });

  test("refuses anything but http(s) with a message the popup shows", () => {
    expect(() => normalizeServerUrl("ftp://x")).toThrow("http:// 或 https://");
    expect(() => normalizeServerUrl("192.168.2.70:7788")).toThrow();
  });
});

describe("socketUrl", () => {
  test("is the Longx origin as ws(s) plus /chrome/socket; phoenix adds /websocket itself", () => {
    expect(socketUrl("http://192.168.2.70:7788")).toBe("ws://192.168.2.70:7788/chrome/socket");
    expect(socketUrl("https://longx.example.com/longx")).toBe("wss://longx.example.com/longx/chrome/socket");
  });
});
