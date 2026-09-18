// `thread:<kernel thread id>` on the wire: join → snapshot, then "event"
// events. A reconnect re-joins and delivers a fresh snapshot, which
// replaces the view (its seq is authoritative); events older than the
// snapshot are dropped by applyEvent. `snapshot()` asks for it again in
// place (after a gap, or a thread/reverted). See LongxWeb.ThreadChannel.
import type { Channel, Socket } from "phoenix";
import type { JoinBreaker } from "./breaker";
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
  socket: Pick<Socket, "channel"> & Partial<Pick<Socket, "onClose" | "off">>,
  kernelThreadId: string,
  handlers: ThreadChannelHandlers,
  opts: { breaker?: JoinBreaker } = {},
): ThreadChannelHandle {
  const topic = `thread:${kernelThreadId}`;
  const channel: Channel = socket.channel(topic, {});
  channel.on("event", (payload: ThreadEvent) => handlers.onEvent(payload));
  // a join that keeps taking the socket down (a reply the server could not
  // encode) is given up after a few closes instead of looping for ever — and
  // the page's other channels keep their connection
  const breaker = opts.breaker;
  let closeRef: string | undefined;
  if (breaker && socket.onClose) {
    breaker.joinSent(topic);
    closeRef = socket.onClose(() => {
      if (breaker.socketClosed().includes(topic)) {
        if (closeRef !== undefined) socket.off?.([closeRef]);
        channel.leave();
        handlers.onError?.({ reason: "unstable", topic });
      }
    });
  }
  channel
    .join()
    .receive("ok", (snapshot: ThreadSnapshot) => {
      breaker?.joined(topic);
      handlers.onSnapshot(snapshot);
    })
    .receive("error", (reason: unknown) => {
      breaker?.joined(topic);
      handlers.onError?.(reason);
    });
  return {
    leave: () => {
      if (closeRef !== undefined) socket.off?.([closeRef]);
      breaker?.reset(topic);
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
