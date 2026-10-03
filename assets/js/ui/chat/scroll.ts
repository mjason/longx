/** Put a thread viewport at its newest content without animating through history. */
export function scrollToBottom(viewport: HTMLElement | null): void {
  if (viewport) viewport.scrollTop = viewport.scrollHeight;
}

/**
 * assistant-ui observes viewport resizing and DOM mutations, not the size of
 * its content. CSS-only disclosure animations (and delayed text layout) resize
 * the content without resizing that viewport; style mutations are intentionally
 * ignored upstream. Publish actual content geometry as a non-style mutation so
 * its existing follow/user-scroll state machine sees the settled layout too.
 * No independent scroll writer: scrolling up must still disable tail-follow.
 */
export function observeThreadContentSize(content: HTMLElement): () => void {
  const observer = new ResizeObserver(([entry]) => {
    if (!entry) return;
    const size = `${entry.contentRect.width}:${entry.contentRect.height}`;
    if (content.getAttribute("data-scroll-size") !== size) {
      content.setAttribute("data-scroll-size", size);
    }
  });
  observer.observe(content);
  return () => observer.disconnect();
}
