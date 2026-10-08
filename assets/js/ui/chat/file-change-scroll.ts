import { flushSync } from "react-dom";

/** Close against final geometry, then keep the sticky title at its reading
 * position in the nearest thread viewport (including nested conversations).
 * Loaded only for file-change disclosure, not on every page's entry path. */
export function collapseFileChange(root: HTMLElement, close: () => void): void {
  const header = root.querySelector<HTMLElement>('[data-slot="collapsible-trigger"]');
  const viewport = root.closest<HTMLElement>('[data-slot="aui_thread-viewport"]');
  if (!header || !viewport) {
    close();
    return;
  }
  const top = header.getBoundingClientRect().top - viewport.getBoundingClientRect().top;
  const focus = root.contains(document.activeElement);
  flushSync(close);
  viewport.scrollTop += header.getBoundingClientRect().top - viewport.getBoundingClientRect().top - top;
  // The footer unmounts: retain keyboard focus without a second browser scroll.
  if (focus) header.focus({ preventScroll: true });
}
