import type { LongxRuntime, LongxRuntimeOptions } from "./runtime";

export type SessionOptions = LongxRuntimeOptions & {
  /** Update this project's workbench without navigating away from another project. */
  onBackgroundThread: (threadId: string) => void;
};

export type ChatSession = {
  id: number;
  key: string;
  options: SessionOptions;
  chat: LongxRuntime | null;
  readers: number;
  attachmentOperations: number;
};

export const sessionKey = (projectId: string, threadId: string | undefined) =>
  JSON.stringify([projectId, threadId ?? null]);

/** Page-scoped live runtimes, not serialized drafts. Retain uploads, File
 * objects and queue drivers while their owner is off screen. Empty inactive
 * sessions leave; no hidden workbench or editor is kept mounted. */
export class ChatSessionPool {
  private byKey = new Map<string, ChatSession>();
  private sessions: readonly ChatSession[] = [];
  private topology = new Set<() => void>();
  private values = new Set<() => void>();
  private pruneTimers = new Map<ChatSession, ReturnType<typeof setTimeout>>();
  private nextId = 0;

  subscribeSessions = (cb: () => void) => { this.topology.add(cb); return () => { this.topology.delete(cb); }; };
  subscribeValues = (cb: () => void) => { this.values.add(cb); return () => { this.values.delete(cb); }; };
  getSessions = () => this.sessions;
  getChat = (key: string) => this.byKey.get(key)?.chat ?? null;

  private notifyTopology() {
    this.sessions = [...new Set(this.byKey.values())];
    this.topology.forEach(cb => cb());
  }
  private notifyValues() { this.values.forEach(cb => cb()); }

  acquire(options: SessionOptions): ChatSession {
    const key = sessionKey(options.projectId, options.threadId);
    let entry = this.byKey.get(key);
    if (!entry) {
      entry = { id: ++this.nextId, key, options, chat: null, readers: 0, attachmentOperations: 0 };
      this.byKey.set(key, entry);
    }
    entry.readers++;
    this.update(entry, options);
    this.cancelPrune(entry);
    this.notifyTopology();
    return entry;
  }

  update(entry: ChatSession, options: SessionOptions) {
    if (entry.options === options) return;
    entry.options = options;
    this.notifyTopology();
  }

  release(entry: ChatSession) {
    entry.readers = Math.max(0, entry.readers - 1);
    this.schedulePrune(entry);
  }

  publish(entry: ChatSession, chat: LongxRuntime) {
    entry.chat = chat;
    this.notifyValues();
    this.schedulePrune(entry);
  }

  attachmentActivity(entry: ChatSession, count: number) {
    entry.attachmentOperations = count;
    this.schedulePrune(entry);
  }

  openThread(entry: ChatSession, threadId: string | null) {
    const options = entry.options;
    if (entry.readers > 0) options.onOpenThread(threadId);
    else if (threadId !== null) options.onBackgroundThread(threadId);
    // A new chat's first send creates its row. Keep the same runtime (and any
    // in-flight send) when the URL/workbench acquires that row's identity.
    if (options.threadId === undefined && threadId !== null) {
      this.byKey.delete(entry.key);
      entry.key = sessionKey(options.projectId, threadId);
      entry.options = { ...options, threadId };
      this.byKey.set(entry.key, entry);
      this.notifyTopology();
      this.notifyValues();
    }
  }

  private cancelPrune(entry: ChatSession) {
    const timer = this.pruneTimers.get(entry);
    if (timer !== undefined) clearTimeout(timer);
    this.pruneTimers.delete(entry);
  }

  schedulePrune(entry: ChatSession) {
    this.cancelPrune(entry);
    if (entry.readers > 0) return;
    // Defer until composer/upload/send microtasks and the host's commit have
    // published their new state; never tear down between clearing chips and
    // enqueuing their completed message.
    this.pruneTimers.set(entry, setTimeout(() => {
      this.pruneTimers.delete(entry);
      if (entry.readers > 0 || entry.attachmentOperations > 0 || !entry.chat) return;
      const state = entry.chat.runtime.thread.composer.getState();
      if (state.attachments.length || state.queue.length || state.text.trim() ||
          entry.chat.echoes.some(echo => !echo.error)) return;
      if (this.byKey.get(entry.key) !== entry) return;
      this.byKey.delete(entry.key);
      this.notifyTopology();
      this.notifyValues();
    }, 0));
  }

  clear() {
    this.pruneTimers.forEach(timer => clearTimeout(timer));
    this.pruneTimers.clear();
    this.byKey.clear();
    this.notifyTopology();
    this.notifyValues();
  }
}
