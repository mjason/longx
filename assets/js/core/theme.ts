// Theme preference: follows the OS by default; dark or light are explicit
// choices. Stored per device.
import { useEffect, useSyncExternalStore } from "react";

export type ThemePreference = "dark" | "light" | "system";
export type ResolvedTheme = "dark" | "light";

const KEY = "longx:theme";
const listeners = new Set<() => void>();

function read(): ThemePreference {
  try {
    const v = localStorage.getItem(KEY);
    return v === "light" || v === "system" || v === "dark" ? v : "system";
  } catch {
    return "system";
  }
}

export function resolveTheme(pref: ThemePreference, systemDark: boolean): ResolvedTheme {
  if (pref === "system") return systemDark ? "dark" : "light";
  return pref;
}

function systemDark(): boolean {
  return typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)").matches : true;
}

export function applyTheme(pref: ThemePreference = read()) {
  const resolved = resolveTheme(pref, systemDark());
  document.documentElement.setAttribute("data-theme", resolved);
}

export function setTheme(pref: ThemePreference) {
  try {
    localStorage.setItem(KEY, pref);
  } catch {
    /* private mode */
  }
  applyTheme(pref);
  listeners.forEach((l) => l());
}

/** dark → light → system → dark (the toggle button's order). */
export function nextTheme(pref: ThemePreference): ThemePreference {
  return pref === "dark" ? "light" : pref === "light" ? "system" : "dark";
}

export function useTheme(): { preference: ThemePreference; resolved: ResolvedTheme; setTheme: typeof setTheme } {
  const preference = useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    read,
    () => "system" as ThemePreference,
  );
  useEffect(() => {
    applyTheme(preference);
    if (preference !== "system" || typeof matchMedia !== "function") return;
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => applyTheme("system");
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [preference]);
  return { preference, resolved: resolveTheme(preference, systemDark()), setTheme };
}
