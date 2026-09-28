// `notify` — Longx.Notify's feed on a page (LongxWeb.NotifyChannel): what
// waits on the person now (the join reply's `running`, `waiting` marked)
// and one event per thing to hear about — an ask waiting, a turn done or
// failed, a watch. The page raises a system notification for it while it is
// out of sight (ui/pwa/PwaBridge) and counts what waits on the app's badge.
// No Web Push: Chrome's goes through FCM, out of reach in China; the page
// open (a tab, the installed app) is the delivery, as for the Android shell.
import type { Channel, Socket } from "phoenix";

export type NotifyKind = "approval" | "turn_completed" | "turn_failed" | "watch";

/** Longx.Notify's event, as the channel pushes it (snake_case keys) */
export type NotifyEvent = {
  kind: NotifyKind;
  title: string;
  body: string;
  /** an SPA path: /p/<slug>/t/<root thread id> */
  url: string;
  project_id: string | null;
  thread_id: string | null;
  at: string;
};

export type NotifyHandlers = {
  onRunning?: (running: { waiting?: boolean }[]) => void;
  onEvent?: (event: NotifyEvent) => void;
};

/** Joins `notify`; returns the function that leaves it. A rejoin (a reconnect) answers `running` again. */
export function joinNotify(socket: Pick<Socket, "channel">, handlers: NotifyHandlers): () => void {
  const channel: Channel = socket.channel("notify", {});
  channel.on("event", (payload: NotifyEvent) => handlers.onEvent?.(payload));
  channel.join().receive("ok", (reply: { running?: { waiting?: boolean }[] }) => handlers.onRunning?.(reply.running ?? []));
  return () => {
    channel.leave();
  };
}

/** Whether to raise a system notification: not while the person is looking at the page. */
export function shouldNotify(page: { visible: boolean; focused: boolean }): boolean {
  return !(page.visible && page.focused);
}

export type NotificationSpec = {
  title: string;
  options: { body: string; tag: string; icon: string; data: { url: string }; requireInteraction: boolean };
};

/** The notification for an event: one per thread and kind, an ask kept until acted on, its page opened on click. */
export function notificationFor(event: NotifyEvent): NotificationSpec {
  return {
    title: event.title,
    options: {
      body: event.body,
      tag: `${event.thread_id ?? event.url}:${event.kind}`,
      icon: "/icons/icon-192.png",
      data: { url: event.url },
      requireInteraction: event.kind === "approval",
    },
  };
}

/** How many threads wait on the person (the app icon's badge). */
export function waitingCount(running: { waiting?: boolean }[] | undefined): number {
  return (running ?? []).filter((r) => r.waiting === true).length;
}
