/** Put a thread viewport at its newest content without animating through history. */
export function scrollToBottom(viewport: HTMLElement | null): void {
  if (viewport) viewport.scrollTop = viewport.scrollHeight;
}
