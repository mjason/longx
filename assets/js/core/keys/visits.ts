// The conversations this page visited, newest first (SPC t l goes back to
// the one before, in whatever project): this session's memory only.
export type Visit = { slug: string; id: string };

const MAX = 20;
let visits: Visit[] = [];

export function noteVisit(slug: string, id: string): void {
  visits = [{ slug, id }, ...visits.filter((v) => v.id !== id)].slice(0, MAX);
}

/** The conversation visited before the one on screen, null when none. */
export function previousVisit(currentId: string | null): Visit | null {
  return visits.find((v) => v.id !== currentId) ?? null;
}

export function _resetVisitsForTests(): void {
  visits = [];
}
