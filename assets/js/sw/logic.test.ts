import { describe, expect, test } from "vitest";
import { assetsCache, classify, markOffline, staleCaches } from "./logic";

const at = (path: string) => new URL(`https://lx.example.com:7443${path}`);
const origin = "https://lx.example.com:7443";

describe("what the service worker does with a request", () => {
  test("hashed assets from the cache, pages from the network (the shell when it is down), icons revalidated", () => {
    expect(classify(at("/assets/index-Ab12.js"), origin, "GET", "no-cors", "script")).toBe("asset");
    expect(classify(at("/p/demo/t/1"), origin, "GET", "navigate", "document")).toBe("navigate");
    expect(classify(at("/"), origin, "GET", "navigate", "document")).toBe("navigate");
    expect(classify(at("/icons/icon-192.png"), origin, "GET", "no-cors", "image")).toBe("static");
    expect(classify(at("/manifest.webmanifest"), origin, "GET", "cors", "manifest")).toBe("static");
  });

  test("the API, the sockets, downloads, webhooks, callbacks, another origin and anything but GET are never touched", () => {
    for (const path of ["/phoenix/live_reload/frame", "/gql", "/api/p/demo", "/socket/websocket", "/files/x/a.png", "/attachments/x", "/hooks/t", "/callback/credentials", "/extension/longx-chrome.zip", "/health", "/sw.js"]) {
      expect(classify(at(path), origin, "GET", "navigate", "document")).toBe("skip");
    }
    expect(classify(at("/assets/a.js"), origin, "POST", "cors", "script")).toBe("skip");
    expect(classify(new URL("https://cdn.example.org/assets/a.js"), origin, "GET", "no-cors", "script")).toBe("skip");
    expect(classify(at("/p/demo"), origin, "GET", "cors", "")).toBe("skip");
    // a frame is a navigation too (dev's live-reload frame, a card's page): never taken for the shell
    expect(classify(at("/some/frame"), origin, "GET", "navigate", "iframe")).toBe("skip");
  });

  test("old builds' caches go, the one before the current stays (a page still open loads its lazy parts from it)", () => {
    const names = [assetsCache("mb1-aaa"), assetsCache("mb3-ccc"), assetsCache("mb2-bbb"), "longx-shell", "someone-else"];
    expect(staleCaches(names, assetsCache("mb3-ccc"))).toEqual([assetsCache("mb1-aaa")]);
    expect(staleCaches([assetsCache("mb3-ccc")], assetsCache("mb3-ccc"))).toEqual([]);
  });
});

test("the shell served from the cache says so on its <html> (the page reloads once the server answers)", () => {
  const html = '<!DOCTYPE html>\n<html lang="zh-CN" data-theme="dark">\n<head></head></html>';
  expect(markOffline(html)).toBe('<!DOCTYPE html>\n<html data-offline-shell="" lang="zh-CN" data-theme="dark">\n<head></head></html>');
  expect(markOffline("no html element")).toBe("no html element");
});
