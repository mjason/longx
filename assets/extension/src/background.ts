// The service worker: one phoenix socket to the Longx the person named, a
// Bridge (relay.ts) on its chrome:bridge channel, and the popup's questions.
// Chrome stops an idle MV3 worker and starts it again for an event, so every
// entry point (an alarm, a message, onStartup) goes through ensure(), which
// rebuilds the connection from chrome.storage.local.
import { Socket } from "phoenix";
import type { PopupMessage, PopupReply, PopupStatus, StatusReport } from "./messages";
import { Bridge, errorMessage, installEventForwarders } from "./relay";
import { normalizeServerUrl, socketUrl } from "./urls";
import { generatedDeviceName, normalizeDeviceName } from "./device-name";

interface Stored {
  installId?: string;
  serverUrl?: string;
  token?: string;
  /** the person pressed 连接 and not 断开 since: reconnect on our own */
  enabled?: boolean;
  name?: string;
  /** Locally chosen name, distinct from the last server display name. */
  deviceName?: string;
  nameRevision?: number;
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
let generation = 0;
let configuring = false;
let changes: Promise<unknown> = Promise.resolve();
let initializing: Promise<Stored> | null = null;
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
  // Serialize user changes; a status poll must not resurrect an old address
  // while a reconnect is writing the new configuration.
  const result = message.type === "status"
    ? handleMessage(message)
    : changes.then(() => handleMessage(message));
  if (message.type !== "status") changes = result.catch(() => undefined);
  result.then(sendResponse, (e: unknown) => sendResponse({ failed: errorMessage(e) }));
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
      const requestedName = message.deviceName === undefined ? undefined : normalizeDeviceName(message.deviceName);
      configuring = true;
      teardown();
      try {
        const stored = await read();
        // A token and display name belong to the Longx that issued them.
        if (stored.serverUrl !== serverUrl) await chrome.storage.local.remove(["token", "name", "status"]);
        await chrome.storage.local.set({ serverUrl, enabled: true } satisfies Stored);
        if (requestedName !== undefined) await saveName(requestedName);
        view = { ...view, status: "connecting", name: null, browserId: null, peerIp: null, sessions: [], error: null };
      } finally {
        configuring = false;
      }
      await ensure();
      break;
    }
    case "rename": {
      const deviceName = normalizeDeviceName(message.deviceName);
      configuring = true;
      teardown();
      try {
        await saveName(deviceName, true);
        view = { ...view, name: deviceName, browserId: null, peerIp: null, sessions: [], error: null };
      } finally {
        configuring = false;
      }
      await ensure();
      break;
    }
    case "disconnect": {
      configuring = true;
      teardown();
      try {
        await chrome.storage.local.set({ enabled: false } satisfies Stored);
        view = { ...view, status: "disconnected", sessions: [], error: null };
      } finally {
        configuring = false;
      }
      break;
    }
    case "status":
      void ensure();
      break;
  }
  return report(await identity());
}

/** Connects when the person wants it and nothing is connecting or connected; safe to call from anywhere. */
function ensure(): Promise<void> {
  if (configuring) return Promise.resolve();
  if (connecting) return connecting;
  const attempt = generation;
  connecting = (async () => {
    const stored = await read();
    if (attempt !== generation || configuring) return;
    const { serverUrl } = stored;
    if (!stored.enabled || !serverUrl) return;
    const state = socket?.connectionState();
    if (state === "open" || state === "connecting") return; // phoenix is on it
    await connect(stored, serverUrl, attempt);
  })().finally(() => {
    connecting = null;
    // A reconnect requested during an asynchronous device/storage read must
    // get its own attempt once the stale attempt unwinds.
    if (attempt !== generation && !configuring) void ensure();
  });
  return connecting;
}

async function connect(stored: Stored, serverUrl: string, attempt: number): Promise<void> {
  const local = await identity();
  const installId = local.installId!;
  const dev = await device(local.deviceName!, local.nameRevision ?? 0);
  if (attempt !== generation || configuring) return;
  teardown(false);
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
        view = { ...view, status: b.status, name: b.name, browserId: b.browserId, peerIp: b.peerIp, sessions: b.sessions, error: b.error };
      },
      reconnect: () => {
        if (bridge !== b) return;
        teardown();
        void ensure();
      },
      disconnect: () => {
        if (bridge !== b) return;
        changes = changes.then(async () => {
          if (bridge !== b) return;
          configuring = true;
          teardown();
          try {
            await chrome.storage.local.set({ enabled: false } satisfies Stored);
          } finally {
            configuring = false;
          }
        }).catch(() => undefined);
      },
    },
  });
  bridge = b;
  s.connect();
  b.start();
}

function teardown(invalidate = true): void {
  if (invalidate) generation += 1;
  const s = socket;
  socket = null;
  bridge?.stop();
  bridge = null;
  s?.disconnect();
}

function report(stored: Stored): StatusReport {
  let status: PopupStatus = view.status;
  // no socket: offline, unless the last word explains why
  if (!socket && status !== "revoked" && status !== "bad_token" && status !== "error") status = "disconnected";
  return { ...view, status, serverUrl: stored.serverUrl ?? null, name: view.name ?? stored.name ?? null, deviceName: stored.deviceName };
}

async function read(): Promise<Stored> {
  return (await chrome.storage.local.get(["installId", "serverUrl", "token", "enabled", "name", "status", "deviceName", "nameRevision"])) as Stored;
}

/** One initializer across popup polls and connection attempts; never duplicate IDs. */
function identity(): Promise<Stored> {
  if (initializing) return initializing;
  initializing = (async () => {
    const stored = await read();
    const installId = stored.installId ?? crypto.randomUUID();
    if (!stored.installId) await chrome.storage.local.set({ installId } satisfies Stored);
    if (!stored.deviceName) {
      const os = await chrome.runtime.getPlatformInfo().then((p) => p.os, () => "unknown");
      const deviceName = stored.name?.trim() || generatedDeviceName(installId, os, navigator.userAgent);
      await chrome.storage.local.set({ deviceName, nameRevision: stored.nameRevision ?? 0 } satisfies Stored);
    }
    return read();
  })().finally(() => { initializing = null; });
  return initializing;
}

async function saveName(deviceName: string, explicit = false): Promise<void> {
  const stored = await identity();
  if (explicit || stored.deviceName !== deviceName) {
    await chrome.storage.local.set({ deviceName, nameRevision: (stored.nameRevision ?? 0) + 1 } satisfies Stored);
  }
}

// Report the stored local nickname on every reconnect, never guess a hostname.
async function device(name: string, nameRevision: number): Promise<{ name: string; name_revision: number; ua: string; platform: string; extension: string }> {
  const ua = navigator.userAgent;
  const platform: string = await chrome.runtime.getPlatformInfo().then(
    (p) => p.os,
    () => "unknown",
  );
  return {
    name,
    name_revision: nameRevision,
    ua,
    platform,
    extension: chrome.runtime.getManifest().version,
  };
}
