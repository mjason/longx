// Pinning is server data; visit order is this device's navigation history.
import { useSyncExternalStore } from "react";

type Project = { id: string; slug: string; pinned: boolean };
const KEY = "longx:project-visits";

function visits(): string[] {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(KEY) ?? "[]");
    return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
  } catch { return []; }
}

export function noteProjectVisit(slug: string): void {
  try { localStorage.setItem(KEY, JSON.stringify([slug, ...visits().filter(s => s !== slug)].slice(0, 100))); }
  catch { /* storage unavailable: navigation still works */ }
}

export function orderedProjects<T extends Project>(projects: readonly T[]): T[] {
  const order = visits();
  const rank = (p: T) => { const i = order.indexOf(p.slug); return i < 0 ? Infinity : i; };
  return [...projects].sort((a, b) => rank(a) - rank(b));
}

export function quickProjects<T extends Project>(projects: readonly T[], current: string, active: ReadonlySet<string>): T[] {
  const all = orderedProjects(projects);
  return [
    ...all.filter(p => p.slug === current),
    ...all.filter(p => p.slug !== current && p.pinned),
    ...all.filter(p => p.slug !== current && !p.pinned && active.has(p.id)),
  ];
}

let pickerOpen = false;
const listeners = new Set<() => void>();
export function setProjectPicker(open: boolean): void {
  pickerOpen = open;
  listeners.forEach(fn => fn());
}
export function useProjectPicker(): boolean {
  return useSyncExternalStore(cb => { listeners.add(cb); return () => listeners.delete(cb); }, () => pickerOpen);
}
