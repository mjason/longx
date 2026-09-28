// Ctrl let go: what cycles while it is held (Ctrl+Tab through the tabs by
// last use) settles on the tab it reached. The dispatcher says so, the
// workbench listens.
const listeners = new Set<() => void>();

export function onModifierRelease(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function modifierReleased(): void {
  listeners.forEach((l) => l());
}
