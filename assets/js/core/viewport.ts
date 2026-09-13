// Which layout the frame uses. Phones get sheets, tablets one side panel,
// desktops the docked IDE layout.
import { useSyncExternalStore } from "react";

export type Viewport = "phone" | "tablet" | "desktop";

export const BREAKPOINTS = { tablet: 768, desktop: 1024 } as const;

export function viewportFor(width: number): Viewport {
  if (width >= BREAKPOINTS.desktop) return "desktop";
  if (width >= BREAKPOINTS.tablet) return "tablet";
  return "phone";
}

function subscribe(cb: () => void) {
  window.addEventListener("resize", cb);
  return () => window.removeEventListener("resize", cb);
}

export function useViewport(): Viewport {
  return useSyncExternalStore(subscribe, () => viewportFor(window.innerWidth), () => "phone");
}
