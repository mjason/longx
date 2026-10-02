// The relay: everything the service worker does with a Longx connection,
// minus the socket, the storage and chrome itself — those are handed in, so
// relay.test.ts runs it against fakes and background.ts is only the wiring.
// The protocol is LongxWeb.ChromeChannel's (docs/browser-design.md §2.1).

// The only chrome.* calls Longx may ask for — Playwright's extension has the
// same shape: positional params, no eval, nothing outside this list.
export const ALLOWED_METHODS: ReadonlySet<string> = new Set([
  "chrome.debugger.attach",
  "chrome.debugger.detach",
  "chrome.debugger.sendCommand",
  "chrome.tabs.create",
  "chrome.tabs.remove",
  "chrome.tabs.update",
  "chrome.tabs.get",
  "chrome.tabs.query",
  "chrome.tabs.group",
  "chrome.tabs.ungroup",
  "chrome.tabGroups.update",
  "chrome.tabGroups.get",
  "chrome.tabGroups.query",
  "chrome.windows.update",
  "chrome.windows.get",
]);

// The events forwarded, each with the arity of its listener: the server
// matches a fixed-length list, and chrome leaves a trailing argument out
// (onEvent's `params` for an event without any) instead of passing undefined.
const FORWARDED_EVENTS: ReadonlyArray<{ method: string; arity: number }> = [
  { method: "chrome.debugger.onEvent", arity: 3 }, // [source, method, params]
  { method: "chrome.debugger.onDetach", arity: 2 }, // [source, reason]
  { method: "chrome.tabs.onCreated", arity: 1 }, // [tab]
  { method: "chrome.tabs.onUpdated", arity: 3 }, // [tabId, changeInfo, tab]
  { method: "chrome.tabs.onRemoved", arity: 2 }, // [tabId, removeInfo]
  { method: "chrome.tabGroups.onRemoved", arity: 1 }, // [group]
];

type AnyFn = (...args: unknown[]) => unknown;

interface ChromeEvent {
  addListener(fn: AnyFn): void;
  removeListener(fn: AnyFn): void;
}

/** `chrome.tabs.create` → the `tabs` namespace and its `create`; null when the path leaves chrome.* or hits nothing. */
export function resolveChromeMember(chromeApi: unknown, path: string): { parent: unknown; member: unknown } | null {
  const [head, ...rest] = path.split(".");
  if (head !== "chrome" || rest.length === 0) return null;
  let parent: unknown = null;
  let member: unknown = chromeApi;
  for (const key of rest) {
    if (member === null || (typeof member !== "object" && typeof member !== "function")) return null;
    parent = member;
    member = (member as Record<string, unknown>)[key];
  }
  return { parent, member };
}

/** Runs one allow-listed `chrome.*` method with positional params; MV3's APIs answer a promise when no callback is given. */
export async function handleCommand(chromeApi: unknown, method: string, params: unknown[]): Promise<unknown> {
  if (!ALLOWED_METHODS.has(method)) throw new Error(`Unknown method: ${method}`);
  const resolved = resolveChromeMember(chromeApi, method);
  if (!resolved || typeof resolved.member !== "function") {
    throw new Error(`${method} is not available in this browser`);
  }
  return await (resolved.member as AnyFn).apply(resolved.parent, params);
}

/**
 * Subscribes to the forwarded events and hands each to `send` in its wire
 * shape. Called once at the top of the service worker (a listener added
 * later would not wake it); `send` looks the live bridge up per event.
 * Returns the uninstall.
 */
export function installEventForwarders(chromeApi: unknown, send: (method: string, params: unknown[]) => void): () => void {
  const installed: { event: ChromeEvent; listener: AnyFn }[] = [];
  for (const { method, arity } of FORWARDED_EVENTS) {
    const event = resolveChromeMember(chromeApi, method)?.member as ChromeEvent | undefined;
    if (!event || typeof event.addListener !== "function") continue; // an API this Chrome lacks
    const listener: AnyFn = (...args) => {
      const params = args.slice(0, arity);
      while (params.length < arity) params.push(null);
      send(method, params);
    };
    event.addListener(listener);
    installed.push({ event, listener });
  }
  return () => installed.forEach(({ event, listener }) => event.removeListener(listener));
}

export type BridgeStatus = "connecting" | "pending" | "approved" | "bad_token" | "revoked" | "error";

export interface SessionInfo {
  title: string;
  tabs: number;
}

export interface ReceiveLike {
  receive(status: string, callback: (response?: unknown) => void): ReceiveLike;
}

/** What the bridge needs of a phoenix Channel. */
export interface ChannelLike {
  on(event: string, callback: (payload?: unknown) => void): unknown;
  push(event: string, payload: object): unknown;
  join(): ReceiveLike;
}

/** What the bridge needs of chrome.storage.local. */
export interface StorageLike {
  set(items: Record<string, unknown>): Promise<void>;
  remove(keys: string | string[]): Promise<void>;
}

export interface BridgeHost {
  /** bad_token after a token was sent: a fresh socket, joining without it (a pending row again). */
  reconnect(): void;
  /** revoked, or a refusal a reconnect cannot mend: offline until the person connects again. */
  disconnect(): void;
  /** status, name or sessions changed (the popup reads them). */
  changed(): void;
}

export interface BridgeOptions {
  chrome: unknown;
  channel: ChannelLike;
  storage: StorageLike;
  host: BridgeHost;
  /** the token this socket connects with, null before pairing */
  token: string | null;
}

/** One `chrome:bridge` channel: the join's pairing reply, the pushes, cmd → result. */
export class Bridge {
  status: BridgeStatus = "connecting";
  name: string | null = null;
  browserId: string | null = null;
  peerIp: string | null = null;
  sessions: SessionInfo[] = [];
  error: string | null = null;
  /**
   * The token as of now — what the socket's params closure must send: phoenix
   * resends the same join after a reconnect, and a join without the token
   * once the row is approved is a bad_token.
   */
  token: string | null;
  private joined = false;
  private stopped = false;
  private readonly opts: BridgeOptions;

  constructor(opts: BridgeOptions) {
    this.opts = opts;
    this.token = opts.token;
  }

  start(): void {
    const { channel } = this.opts;
    channel.on("cmd", (payload) => void this.command(payload));
    channel.on("approved", (payload) => void this.approved(payload));
    channel.on("revoked", () => void this.revoked());
    channel.on("state", (payload) => this.state(payload));
    channel
      .join()
      .receive("ok", (reply) => void this.joinReply(reply))
      .receive("error", (reason) => this.fail(describeJoinError(reason)))
      .receive("timeout", () => this.fail("join timed out"));
  }

  /** A superseded socket must not handle late pairing replies or commands. */
  stop(): void {
    this.stopped = true;
    this.joined = false;
  }

  /** A chrome.* event for the server; nothing goes out before the join (the server drops it anyway). */
  sendEvent(method: string, params: unknown[]): void {
    if (!this.joined) return;
    this.opts.channel.push("event", { method, params });
  }

  private async joinReply(reply: unknown): Promise<void> {
    if (this.stopped) return;
    const r = asRecord(reply);
    const name = typeof r.name === "string" ? r.name : null;
    this.browserId = typeof r.browser_id === "string" ? r.browser_id : null;
    this.peerIp = typeof r.peer_ip === "string" ? r.peer_ip : null;
    switch (r.status) {
      case "approved":
      case "pending":
        this.joined = true;
        this.name = name;
        await this.setStatus(r.status);
        return;
      case "bad_token": {
        const hadToken = this.token !== null;
        this.token = null;
        await this.opts.storage.remove("token");
        if (this.stopped) return;
        await this.setStatus("bad_token");
        if (this.stopped) return;
        // without a token there is nothing to retry with: the row is approved
        // on the server and this install lost its copy — the person revokes it
        // there and connects again
        if (hadToken) this.opts.host.reconnect();
        else this.opts.host.disconnect();
        return;
      }
      default:
        this.fail(`unexpected join reply: ${JSON.stringify(reply)}`);
    }
  }

  private async approved(payload: unknown): Promise<void> {
    if (this.stopped) return;
    const p = asRecord(payload);
    if (typeof p.token !== "string") return;
    if (typeof p.name === "string") this.name = p.name;
    this.token = p.token;
    // The socket's params closure must see the token immediately, including
    // a transport reconnect before storage finishes persisting it.
    this.opts.host.changed();
    await this.opts.storage.set({ token: p.token });
    if (this.stopped) return;
    await this.setStatus("approved");
  }

  private async revoked(): Promise<void> {
    if (this.stopped) return;
    this.token = null;
    await this.opts.storage.remove("token");
    if (this.stopped) return;
    await this.setStatus("revoked");
    if (this.stopped) return;
    this.opts.host.disconnect();
  }

  private state(payload: unknown): void {
    if (this.stopped) return;
    const sessions = asRecord(payload).sessions;
    this.sessions = Array.isArray(sessions)
      ? sessions.map((s) => {
          const r = asRecord(s);
          return { title: typeof r.title === "string" ? r.title : "", tabs: typeof r.tabs === "number" ? r.tabs : 0 };
        })
      : [];
    this.opts.host.changed();
  }

  private async command(payload: unknown): Promise<void> {
    if (this.stopped) return;
    const { id, method, params } = asRecord(payload);
    const args = Array.isArray(params) ? params : [];
    let answer: { id: unknown; result: unknown } | { id: unknown; error: string };
    try {
      const result = await handleCommand(this.opts.chrome, String(method), args);
      // the wire has no undefined: a void call answers an empty object
      answer = { id, result: result === undefined ? {} : result };
    } catch (e) {
      answer = { id, error: errorMessage(e) };
    }
    if (!this.stopped) this.opts.channel.push("result", answer);
  }

  private fail(message: string): void {
    if (this.stopped) return;
    this.error = message;
    this.status = "error";
    this.opts.host.changed();
  }

  private async setStatus(status: BridgeStatus): Promise<void> {
    if (this.stopped) return;
    this.status = status;
    this.error = null;
    this.opts.host.changed();
    // mirrored for a popup opened while the worker is being restarted
    await this.opts.storage.set(this.name === null ? { status } : { status, name: this.name });
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

export function errorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  if (typeof e === "string") return e;
  const m = asRecord(e).message;
  return typeof m === "string" ? m : JSON.stringify(e) ?? String(e);
}

function describeJoinError(reason: unknown): string {
  const r = asRecord(reason).reason;
  return typeof r === "string" ? r : `join refused: ${JSON.stringify(reason)}`;
}
