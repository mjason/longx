/** What the person typed → `http://host:7788` (a path prefix kept: Longx may sit behind a proxy's path). */
export function normalizeServerUrl(input: string): string {
  let url: URL;
  try {
    url = new URL(input.trim());
  } catch {
    throw new Error("地址要以 http:// 或 https:// 开头，例如 http://192.168.2.70:7788");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("地址要以 http:// 或 https:// 开头");
  url.pathname = url.pathname.replace(/\/+$/, "");
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/$/, "");
}

/** `http://host:7788` → `ws://host:7788/chrome/socket` (phoenix appends `/websocket`). */
export function socketUrl(serverUrl: string): string {
  const url = new URL(serverUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = url.pathname.replace(/\/+$/, "") + "/chrome/socket";
  url.search = "";
  url.hash = "";
  return url.toString();
}
