// `thread:<kernel thread id>` on the wire: join → snapshot, then "event"
// events. A reconnect re-joins and delivers a fresh snapshot, which
// replaces the view (its seq is authoritative); events older than the
// snapshot are dropped by applyEvent. `snapshot()` asks for it again in
// place (after a gap, or a thread/reverted). See LongxWeb.ThreadChannel.
import type { Channel, Socket } from "phoenix";
import type { ThreadEvent, ThreadSnapshot } from "./thread";

export type ThreadChannelHandlers = {
  onSnapshot: (snapshot: ThreadSnapshot) => void;
  onEvent: (event: ThreadEvent) => void;
  onError?: (reason: unknown) => void;
};

export type ThreadChannelHandle = {
  leave: () => void;
  /** re-pulls the snapshot; resolves once it has been handed to onSnapshot */
  snapshot: () => Promise<void>;
};

export function joinThreadChannel(
  socket: Pick<Socket, "channel">,
  kernelThreadId: string,
  handlers: ThreadChannelHandlers,
): ThreadChannelHandle {
  const channel: Channel = socket.channel(`thread:${kernelThreadId}`, {});
  channel.on("event", (payload: ThreadEvent) => handlers.onEvent(payload));
  channel
    .join()
    .receive("ok", (snapshot: ThreadSnapshot) => handlers.onSnapshot(snapshot))
    .receive("error", (reason: unknown) => handlers.onError?.(reason));
  return {
    leave: () => {
      channel.leave();
    },
    snapshot: () =>
      new Promise<void>((resolve, reject) => {
        channel
          .push("snapshot", {})
          .receive("ok", (snapshot: ThreadSnapshot) => {
            handlers.onSnapshot(snapshot);
            resolve();
          })
          .receive("error", (reason: unknown) => reject(reason))
          .receive("timeout", () => reject(new Error("snapshot timed out")));
      }),
  };
}
