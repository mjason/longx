// A command that has to reach a part of the page that may not be on screen
// yet — `SPC g b` opens the Git window, then its branch list — asks for an
// intent: the part handles it when mounted, or on mounting when the intent
// was asked for before it was there.
import { useEffect, useRef } from "react";

type Handler = (payload: unknown) => void;

const handlers = new Map<string, Set<Handler>>();
const pending = new Map<string, unknown>();

export function requestIntent(name: string, payload?: unknown): void {
  const set = handlers.get(name);
  if (set && set.size > 0) {
    pending.delete(name);
    set.forEach((h) => h(payload));
  } else {
    pending.set(name, payload);
  }
}

/** Handles an intent while mounted; one asked for before the mount is handled on it. */
export function useIntent(name: string, handler: (payload: unknown) => void): void {
  const latest = useRef(handler);
  latest.current = handler;
  useEffect(() => {
    const h: Handler = (payload) => latest.current(payload);
    const set = handlers.get(name) ?? new Set<Handler>();
    set.add(h);
    handlers.set(name, set);
    if (pending.has(name)) {
      const payload = pending.get(name);
      pending.delete(name);
      h(payload);
    }
    return () => {
      set.delete(h);
    };
  }, [name]);
}

export function _resetIntentsForTests(): void {
  handlers.clear();
  pending.clear();
}
