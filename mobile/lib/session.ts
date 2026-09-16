// Which server, which token: the app's one piece of state that outlives a
// launch. Kept in the secure store, pushed into the core's transport so the
// RPC client, the socket and uploads all go to the paired server with the
// device's bearer.
import * as SecureStore from "expo-secure-store";
import { Platform } from "react-native";
import { configureTransport } from "@/core/transport";

// the secure store has no web implementation; the web export (a dev
// check, react-native-web) keeps the session in localStorage
const store = {
  get: (key: string) => (Platform.OS === "web" ? Promise.resolve(globalThis.localStorage?.getItem(key) ?? null) : SecureStore.getItemAsync(key)),
  set: (key: string, value: string) => (Platform.OS === "web" ? Promise.resolve(void globalThis.localStorage?.setItem(key, value)) : SecureStore.setItemAsync(key, value)),
  remove: (key: string) => (Platform.OS === "web" ? Promise.resolve(void globalThis.localStorage?.removeItem(key)) : SecureStore.deleteItemAsync(key)),
};

export type Session = {
  baseUrl: string;
  token: string;
  serverVersion: string | null;
  deviceName: string;
};

const KEY = "longx.session";

/** what the person typed → the server's origin (`http://` assumed for a bare host:port) */
export function serverOrigin(input: string): string | null {
  const text = input.trim().replace(/\/+$/, "");
  if (!text) return null;
  const withScheme = /^https?:\/\//.test(text) ? text : `http://${text}`;
  try {
    const url = new URL(withScheme);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (!url.hostname) return null;
    return `${url.protocol}//${url.host}`;
  } catch {
    return null;
  }
}

function apply(session: Session | null) {
  configureTransport(session ? { baseUrl: session.baseUrl, token: session.token } : { baseUrl: "", token: null });
}

export async function loadSession(): Promise<Session | null> {
  const raw = await store.get(KEY);
  const session = raw ? (JSON.parse(raw) as Session) : null;
  apply(session);
  return session;
}

export async function saveSession(session: Session): Promise<void> {
  await store.set(KEY, JSON.stringify(session));
  apply(session);
}

export async function clearSession(): Promise<void> {
  await store.remove(KEY);
  apply(null);
}

/** POST /pair with the code from Settings → 移动端; the token comes back once */
export async function pairWithServer(server: string, code: string, deviceName: string): Promise<Session> {
  const baseUrl = serverOrigin(server);
  if (!baseUrl) throw new Error("这不是一个地址");
  const response = await fetch(`${baseUrl}/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code, name: deviceName, platform: Platform.OS === "ios" ? "ios" : Platform.OS === "android" ? "android" : "other" }),
  });
  const json = (await response.json().catch(() => ({}))) as { token?: string; error?: string; server?: { version?: string } };
  if (!response.ok || !json.token) throw new Error(json.error ?? `配对失败（${response.status}）`);
  const session: Session = { baseUrl, token: json.token, serverVersion: json.server?.version ?? null, deviceName };
  apply(session);
  return session;
}
