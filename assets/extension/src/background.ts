// The service worker: one phoenix socket to the Longx the person named, a
// Bridge (relay.ts) on its chrome:bridge channel, and the popup's questions.
// Chrome stops an idle MV3 worker and starts it again for an event, so every
// entry point (an alarm, a message, onStartup) goes through ensure(), which
// rebuilds the connection from chrome.storage.local.
import { Socket } from "phoenix";
import type { PopupMessage, PopupReply, PopupStatus, StatusReport } from "./messages";
import { Bridge, errorMessage, installEventForwarders } from "./relay";
import { normalizeServerUrl, socketUrl } from "./urls";

interface Stored {
  installId?: string;
  serverUrl?: string;
  token?: string;
  /** the person pressed 连接 and not 断开 since: reconnect on our own */
  enabled?: boolean;
  name?: string;
  status?: string;
}

const ALARM = "longx-reconnect";
// phoenix's 30 s heartbeat keeps the worker alive while the socket is open;
// the alarm is the fallback for a socket that died while the worker slept
const ALARM_PERIOD_MINUTES = 0.5;

let socket: Socket | null = null;
let bridge: Bridge | null = null;
// what the socket's params closure sends: phoenix runs it on every
// (re)connect, so a socket paired during its life rejoins with the token
let token: string | null = null;
let connecting: Promise<void> | null = null;
let view: StatusReport = { status: "disconnected", name: null, serverUrl: null, sessions: [], error: null };

// registered synchronously at the top: a listener added later would not
// wake the worker for the event; the bridge of the moment gets each one
installEventForwarders(chrome, (method, params) => bridge?.sendEvent(method, params));

chrome.runtime.onInstalled.addListener(() => void ensure());
chrome.runtime.onStartup.addListener(() => void ensure());
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM) void ensure();
});
chrome.runtime.onMessage.addListener((message: PopupMessage, _sender, sendResponse: (r: PopupReply) => void) => {
  handleMessage(message).then(sendResponse, (e: unknown) => sendResponse({ failed: errorMessage(e) }));
  return true; // the answer comes asynchronously
});

void chrome.alarms.get(ALARM).then((alarm) => {
  if (!alarm) void chrome.alarms.create(ALARM, { periodInMinutes: ALARM_PERIOD_MINUTES });
});
void ensure();

async function handleMessage(message: PopupMessage): Promise<StatusReport> {
  switch (message.type) {
    case "connect": {
      const serverUrl = normalizeServerUrl(message.serverUrl);
      const stored = await read();
      // a token belongs to the Longx that issued it
      if (stored.serverUrl !== serverUrl) await chrome.storage.local.remove("token");
      await chrome.storage.local.set({ serverUrl, enabled: true } satisfies Stored);
      teardown();
      view = { ...view, status: "connecting", error: null };
      await ensure();
      break;
    }
    case "disconnect":
      await chrome.storage.local.set({ enabled: false } satisfies Stored);
      teardown();
      view = { ...view, status: "disconnected", sessions: [], error: null };
      break;
    case "status":
      void ensure();
      break;
  }
  return report(await read());
}

/** Connects when the person wants it and nothing is connecting or connected; safe to call from anywhere. */
function ensure(): Promise<void> {
  if (connecting) return connecting;
  connecting = (async () => {
    const stored = await read();
    const { serverUrl } = stored;
    if (!stored.enabled || !serverUrl) return;
    const state = socket?.connectionState();
    if (state === "open" || state === "connecting") return; // phoenix is on it
    await connect(stored, serverUrl);
  })().finally(() => (connecting = null));
  return connecting;
}

async function connect(stored: Stored, serverUrl: string): Promise<void> {
  teardown();
  const installId = stored.installId ?? (await newInstallId());
  const dev = await device();
  token = stored.token ?? null;
  const s = new Socket(socketUrl(serverUrl), { params: () => ({ install_id: installId, token, device: dev }) });
  socket = s;
  view = { ...view, status: "connecting", serverUrl, error: null };
  s.onError(() => {
    if (socket === s) view = { ...view, status: "connecting", error: `无法连接到 ${serverUrl}` };
  });
  s.onClose(() => {
    // phoenix reconnects on its own and the channel rejoins: the bridge sees
    // a fresh join reply and its state follows the new socket
    if (socket === s && view.status !== "revoked" && view.status !== "bad_token") view = { ...view, status: "connecting" };
  });

  const b = new Bridge({
    chrome,
    channel: s.channel("chrome:bridge", {}),
    storage: chrome.storage.local,
    token,
    host: {
      changed: () => {
        if (bridge !== b) return;
        token = b.token;
        view = { ...view, status: b.status, name: b.name, sessions: b.sessions, error: b.error };
      },
      reconnect: () => {
        if (bridge !== b) return;
        teardown();
        void ensure();
      },
      disconnect: () => {
        if (bridge !== b) return;
        teardown();
        void chrome.storage.local.set({ enabled: false } satisfies Stored);
      },
    },
  });
  bridge = b;
  s.connect();
  b.start();
}

function teardown(): void {
  const s = socket;
  socket = null;
  bridge = null;
  s?.disconnect();
}

function report(stored: Stored): StatusReport {
  let status: PopupStatus = view.status;
  // no socket: offline, unless the last word explains why
  if (!socket && status !== "revoked" && status !== "bad_token" && status !== "error") status = "disconnected";
  return { ...view, status, serverUrl: stored.serverUrl ?? null, name: view.name ?? stored.name ?? null };
}

async function read(): Promise<Stored> {
  return (await chrome.storage.local.get(["installId", "serverUrl", "token", "enabled", "name", "status"])) as Stored;
}

async function newInstallId(): Promise<string> {
  const installId = crypto.randomUUID();
  await chrome.storage.local.set({ installId } satisfies Stored);
  return installId;
}

const OS_LABELS: Record<string, string> = { mac: "macOS", win: "Windows", linux: "Linux", cros: "ChromeOS", android: "Android" };

// what the server shows for this browser until the person renames it:
// "Chrome 153 · macOS" (an extension knows no machine name)
async function device(): Promise<{ name: string; ua: string; platform: string; extension: string }> {
  const ua = navigator.userAgent;
  const platform: string = await chrome.runtime.getPlatformInfo().then(
    (p) => p.os,
    () => "unknown",
  );
  const major = /Chrom(?:e|ium)\/(\d+)/.exec(ua)?.[1];
  const browser = major ? `Chrome ${major}` : "Chrome";
  return {
    name: `${browser} · ${OS_LABELS[platform] ?? platform}`,
    ua,
    platform,
    extension: chrome.runtime.getManifest().version,
  };
}
