// Theme preference: dark is the product default; "system" follows the OS;
// light is an explicit override. Stored per device.
import { useEffect, useSyncExternalStore } from "react";

export type ThemePreference = "dark" | "light" | "system";
export type ResolvedTheme = "dark" | "light";

const KEY = "longx:theme";
const listeners = new Set<() => void>();

function read(): ThemePreference {
  try {
    const v = localStorage.getItem(KEY);
    return v === "light" || v === "system" || v === "dark" ? v : "dark";
  } catch {
    return "dark";
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

export function useTheme(): { preference: ThemePreference; resolved: ResolvedTheme; setTheme: typeof setTheme } {
  const preference = useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    read,
    () => "dark" as ThemePreference,
  );
  useEffect(() => applyTheme(preference), [preference]);
  return { preference, resolved: resolveTheme(preference, systemDark()), setTheme };
}
