// This device's choices for the keyboard and the PWA: the space menu (on
// unless turned off), system notifications (off until asked for — the
// browser's permission goes with it), the offline cache (the service
// worker; on unless turned off), whether the model's reasoning opens
// unfolded (SPC T r). localStorage, per device.
import { useSyncExternalStore } from "react";

export type Preference = "spaceMenu" | "notifications" | "offlineCache" | "reasoningOpen";

const KEYS: Record<Preference, string> = {
  spaceMenu: "longx:space-menu",
  notifications: "longx:notifications",
  offlineCache: "longx:offline-cache",
  reasoningOpen: "longx:reasoning-open",
};
const DEFAULTS: Record<Preference, boolean> = { spaceMenu: true, notifications: false, offlineCache: true, reasoningOpen: false };

const listeners = new Set<() => void>();

export function getPreference(name: Preference): boolean {
  try {
    const raw = localStorage.getItem(KEYS[name]);
    return raw === null ? DEFAULTS[name] : raw === "on";
  } catch {
    return DEFAULTS[name];
  }
}

export function setPreference(name: Preference, on: boolean): void {
  try {
    localStorage.setItem(KEYS[name], on ? "on" : "off");
  } catch {
    /* private mode */
  }
  listeners.forEach((l) => l());
}

export function usePreference(name: Preference): boolean {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => getPreference(name),
    () => DEFAULTS[name],
  );
}
