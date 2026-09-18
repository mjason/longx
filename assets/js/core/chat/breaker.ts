// Two circuit breakers for the socket, DOM-free.
//
// A join that kills the socket (a payload the server could not encode, once)
// used to loop: connect, join, close, reconnect — 146 times in five seconds,
// and every other channel on the socket with it. `createJoinBreaker` counts
// socket closes that land while a channel's join is pending and, at `limit`,
// gives that channel up (the caller leaves it and shows why); the rest of
// the page keeps its connection. `createCloseTracker` watches the socket as
// a whole: too many closes in a window is "unstable" — the banner says so
// and reconnects slow down — until it stays open for a while.

export type JoinBreaker = {
  joinSent: (topic: string) => void;
  joined: (topic: string) => void;
  reset: (topic: string) => void;
  /** the socket closed: the topics whose pending join just tripped the limit */
  socketClosed: () => string[];
  tripped: (topic: string) => boolean;
};

export function createJoinBreaker({ limit = 3 }: { limit?: number } = {}): JoinBreaker {
  const pending = new Set<string>();
  const closes = new Map<string, number>();
  const tripped = new Set<string>();
  return {
    joinSent: (topic) => {
      if (!tripped.has(topic)) pending.add(topic);
    },
    joined: (topic) => {
      pending.delete(topic);
      closes.delete(topic);
    },
    reset: (topic) => {
      pending.delete(topic);
      closes.delete(topic);
      tripped.delete(topic);
    },
    socketClosed: () => {
      const now: string[] = [];
      for (const topic of pending) {
        const n = (closes.get(topic) ?? 0) + 1;
        closes.set(topic, n);
        if (n >= limit) {
          tripped.add(topic);
          pending.delete(topic);
          now.push(topic);
        }
      }
      return now;
    },
    tripped: (topic) => tripped.has(topic),
  };
}

export type CloseTracker = {
  /** a close at `now` (ms); true when the socket is unstable from here */
  closed: (now: number) => boolean;
  opened: (now: number) => void;
  unstable: (now: number) => boolean;
  /** phoenix's reconnect ladder, or a slow steady retry while unstable */
  reconnectAfterMs: (tries: number, now: number) => number;
};

// phoenix's own ladder
const LADDER = [10, 50, 100, 150, 200, 250, 500, 1000, 2000];

export function createCloseTracker({
  limit = 5,
  windowMs = 60_000,
  calmMs = 30_000,
}: { limit?: number; windowMs?: number; calmMs?: number } = {}): CloseTracker {
  let recent: number[] = [];
  let unstableSince: number | null = null;
  let openSince: number | null = null;
  const unstable = (now: number) => {
    if (unstableSince === null) return false;
    // calm: the socket has been open, without a close, for `calmMs`
    if (openSince !== null && now - openSince >= calmMs) {
      unstableSince = null;
      recent = [];
      return false;
    }
    return true;
  };
  return {
    closed: (now) => {
      openSince = null;
      recent = recent.filter((t) => now - t < windowMs);
      recent.push(now);
      if (recent.length >= limit) unstableSince = now;
      return unstable(now);
    },
    opened: (now) => {
      openSince = now;
    },
    unstable,
    reconnectAfterMs: (tries, now) =>
      unstable(now) ? 5_000 + Math.min(tries, 5) * 1_000 : (LADDER[tries - 1] ?? 5_000),
  };
}
