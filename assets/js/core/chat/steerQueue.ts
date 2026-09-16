// assistant-ui only lets the composer send while a turn runs when the
// runtime has a queue adapter; its own (`createMessageQueue`) would hold the
// message until the turn ends. Codex injects it into the running turn
// instead (turn/steer), so this "queue" keeps nothing: every message goes
// straight to the adapter's onNew, which steers while a turn runs and
// starts a turn otherwise.
import type { AppendMessage, ExternalThreadQueueAdapter } from "@assistant-ui/react";

export function createSteerQueue(onNew: (message: AppendMessage) => Promise<void>): ExternalThreadQueueAdapter {
  const dispatch = (message: AppendMessage) => void onNew(message);
  return {
    items: [],
    steerItems: [],
    enqueue: dispatch,
    steer: dispatch,
    move: () => {},
    edit: () => {},
    remove: () => {},
  };
}
