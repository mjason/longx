import { createMessageQueue, type AppendMessage } from "@assistant-ui/react";

type Driver = Parameters<typeof createMessageQueue>[0] & {
  /** Buffered person messages go to one request, without flattening their inputs. */
  runBatch?: (messages: AppendMessage[]) => Promise<void>;
};

/**
 * QueueItem.parts is a display projection: assistant-ui drops attachment text
 * (inline files and uploaded paths). Keep the original until the item leaves,
 * so "insert now" uses the same input as an ordinary queued send.
 */
export function createQueuedMessages(driver: Driver) {
  const originals = new Map<string, AppendMessage>();
  let dispatchTransform = (message: AppendMessage) => message;
  const queue = createMessageQueue({
    ...driver,
    run: (first, options) => {
      const remaining = [...queue.adapter.steerItems, ...queue.adapter.items];
      if (!driver.runBatch || options.steer || remaining.length === 0) {
        driver.run(first, options);
        return;
      }
      const messages = [first, ...remaining.map(item => dispatchTransform(originals.get(item.id)!))];
      remaining.forEach(item => queue.adapter.remove(item.id));
      // The controller already marked this dispatch busy. New sends wait
      // behind the batch, and a failure restores it without an automatic loop.
      void driver.runBatch(messages).catch(() => {
        const later = [...queue.adapter.steerItems, ...queue.adapter.items];
        messages.forEach(message => queue.adapter.enqueue(message));
        const restored = queue.adapter.items.slice(-messages.length);
        for (let index = restored.length - 1; index >= 0; index--) {
          queue.adapter.move!(restored[index]!.id, { lane: "queue", insertAfter: null });
        }
        // A failed dispatch has no turn to settle; retain all inputs paused.
        queue.notifyCancelled();
        queue.notifyIdle();
        // Keep messages received during the RPC after the restored batch.
        later.forEach(item => {
          if (queue.adapter.steerItems.some(current => current.id === item.id)) {
            queue.adapter.move!(item.id, { lane: "queue" });
          }
        });
      });
    },
  });
  const installTransform = queue.adapter.__internal_setDispatchTransform!;
  queue.adapter.__internal_setDispatchTransform = (transform) => {
    dispatchTransform = transform;
    installTransform(transform);
  };
  let adding: AppendMessage | undefined;
  // Registered before UI subscribers: originals are available in the same
  // notification that publishes an item, and disappear on remove/drain/clear.
  queue.subscribe(() => {
    const ids = new Set([...queue.adapter.items, ...queue.adapter.steerItems].map((item) => item.id));
    for (const id of originals.keys()) {
      if (!ids.has(id)) originals.delete(id);
    }
    if (adding) {
      for (const id of ids) {
        if (!originals.has(id)) originals.set(id, adding);
      }
    }
  });
  for (const method of ["enqueue", "steer"] as const) {
    const push = queue.adapter[method];
    queue.adapter[method] = (message) => {
      const previous = adding;
      adding = message;
      try {
        push(message);
      } finally {
        adding = previous;
      }
    };
  }
  const edit = queue.adapter.edit!;
  queue.adapter.edit = (id, message) => {
    const previous = originals.get(id);
    if (!previous) return edit(id, message); // preserve the unknown-id error
    originals.set(id, message);
    try {
      edit(id, message);
    } catch (error) {
      originals.set(id, previous);
      throw error;
    }
  };
  return Object.assign(queue, {
    getOriginal: (id: string) => originals.get(id),
    /** Same item cannot be sent twice by repeated clicks before the RPC settles. */
    inserting: new Set<string>(),
  });
}

export type QueuedMessages = ReturnType<typeof createQueuedMessages>;
