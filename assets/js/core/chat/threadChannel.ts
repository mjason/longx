// `thread:<codex_thread_id>` on the wire: join → snapshot, then "codex"
// events. A reconnect re-joins and delivers a fresh snapshot, which
// replaces the view (its seq is authoritative); events older than the
// snapshot are dropped by applyEvent. See LongxWeb.ThreadChannel.
import type { Channel, Socket } from "phoenix";
import type { ThreadEvent, ThreadSnapshot } from "./thread";

export type ThreadChannelHandlers = {
  onSnapshot: (snapshot: ThreadSnapshot) => void;
  onEvent: (event: ThreadEvent) => void;
  onError?: (reason: unknown) => void;
};

export function joinThreadChannel(
  socket: Pick<Socket, "channel">,
  codexThreadId: string,
  handlers: ThreadChannelHandlers,
): () => void {
  const channel: Channel = socket.channel(`thread:${codexThreadId}`, {});
  channel.on("codex", (payload: ThreadEvent) => handlers.onEvent(payload));
  channel
    .join()
    .receive("ok", (snapshot: ThreadSnapshot) => handlers.onSnapshot(snapshot))
    .receive("error", (reason: unknown) => handlers.onError?.(reason));
  return () => {
    channel.leave();
  };
}
