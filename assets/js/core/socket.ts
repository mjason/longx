// One Phoenix socket per page, shared by every channel (threads, projects).
// Status is what the connection banner shows; a phone coming back from the
// background reconnects here and every channel re-joins on its own.
import { Socket } from "phoenix";
import { createCloseTracker, createJoinBreaker, type JoinBreaker } from "@/core/chat/breaker";

// "unstable": the socket closed too often in the last minute (a join the
// server could not answer, a flapping network) — the banner says so and the
// reconnects slow down until it stays open for a while
export type SocketStatus = "connecting" | "open" | "closed" | "unstable";

type Listener = (status: SocketStatus) => void;

let socket: Socket | null = null;
const listeners = new Set<Listener>();
let status: SocketStatus = "connecting";
const closes = createCloseTracker();
// one breaker for every channel of the page: a join that keeps killing the
// socket is given up, the rest keep their connection (threadChannel.ts)
const breaker: JoinBreaker = createJoinBreaker();

function setStatus(next: SocketStatus) {
  if (next === status) return;
  status = next;
  listeners.forEach((l) => l(next));
}

export function getSocket(): Socket {
  if (socket) return socket;
  socket = new Socket("/socket", {
    params: {},
    reconnectAfterMs: (tries: number) => closes.reconnectAfterMs(tries, Date.now()),
  });
  socket.onOpen(() => {
    closes.opened(Date.now());
    setStatus("open");
  });
  socket.onClose(() => setStatus(closes.closed(Date.now()) ? "unstable" : "closed"));
  socket.onError(() => setStatus(closes.unstable(Date.now()) ? "unstable" : "closed"));
  socket.connect();
  return socket;
}

export function joinBreaker(): JoinBreaker {
  return breaker;
}

/** A shell back from the background: a dead connection is torn down and reopened at once, not after the backoff. */
export function reconnectSocket(): void {
  if (!socket || socket.isConnected()) return;
  socket.disconnect(() => socket?.connect());
}

export function socketStatus(): SocketStatus {
  return status;
}

export function onSocketStatus(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Tests inject a fake; production never calls this. */
export function _setSocketForTests(fake: Socket | null, initial: SocketStatus = "open") {
  socket = fake;
  status = initial;
}
