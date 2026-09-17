// Coalesces a burst of channel events into one state update per animation
// frame: the kernel streams reasoning / output deltas every few milliseconds, and
// a React commit per delta cannot keep up — React then sees a commit that
// always leaves work pending and stops it as a runaway update loop
// ("Maximum update depth exceeded"). One fold per frame keeps the view
// current and gives every commit a quiet end.

export type Batcher<T> = { push: (item: T) => void; cancel: () => void };

export type Schedule = (flush: () => void) => void;

/** Test builds fold at once; the browser folds once per frame. */
export const frameSchedule: Schedule =
  import.meta.env.MODE === "test" || typeof requestAnimationFrame !== "function" ? (cb) => cb() : (cb) => void requestAnimationFrame(cb);

export function createBatcher<T>(flush: (items: T[]) => void, schedule: Schedule = frameSchedule): Batcher<T> {
  let pending: T[] = [];
  let scheduled = false;
  return {
    push(item) {
      pending.push(item);
      if (scheduled) return;
      scheduled = true;
      schedule(() => {
        scheduled = false;
        const items = pending;
        pending = [];
        if (items.length) flush(items);
      });
    },
    cancel() {
      pending = [];
    },
  };
}
