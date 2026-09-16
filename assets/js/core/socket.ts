// One Phoenix socket per page, shared by every channel (threads, projects).
// Status is what the connection banner shows; a phone coming back from the
// background reconnects here and every channel re-joins on its own.
import { Socket } from "phoenix";

export type SocketStatus = "connecting" | "open" | "closed";

type Listener = (status: SocketStatus) => void;

let socket: Socket | null = null;
const listeners = new Set<Listener>();
let status: SocketStatus = "connecting";

function setStatus(next: SocketStatus) {
  if (next === status) return;
  status = next;
  listeners.forEach((l) => l(next));
}

export function getSocket(): Socket {
  if (socket) return socket;
  socket = new Socket("/socket", { params: {} });
  socket.onOpen(() => setStatus("open"));
  socket.onClose(() => setStatus("closed"));
  socket.onError(() => setStatus("closed"));
  socket.connect();
  return socket;
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
