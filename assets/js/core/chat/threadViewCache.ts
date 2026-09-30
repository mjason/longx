import type { ThreadView } from "./thread";

const MAX_THREADS = 6;
const MAX_ITEMS_PER_THREAD = 3000;
const views = new Map<string, ThreadView>();

/** Small in-memory LRU for recently visited conversations; never persisted. */
export function getCachedThreadView(id: string): ThreadView | undefined {
  const view = views.get(id);
  if (!view) return undefined;
  views.delete(id);
  views.set(id, view);
  return view;
}

export function cacheThreadView(view: ThreadView): void {
  if (!view.threadId) return;
  const excess = view.items.length - MAX_ITEMS_PER_THREAD;
  const cached = excess > 0
    ? { ...view, items: view.items.slice(excess), earlier: { ...view.earlier, items: view.earlier.items + excess } }
    : view;
  views.delete(view.threadId);
  views.set(view.threadId, cached);
  while (views.size > MAX_THREADS) views.delete(views.keys().next().value!);
}

export function clearCachedThreadView(id: string): void {
  views.delete(id);
}

// Kept explicit for isolated tests and lifecycle events such as logout.
export function clearThreadViewCache(): void {
  views.clear();
}
