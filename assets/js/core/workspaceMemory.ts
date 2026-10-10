// In-page buffers survive navigation without keeping hidden editors/runtimes
// mounted (and subscribing to every project's channels). Never write file
// contents or attachment bytes into localStorage.
const drafts = new Map<string, string>();
const disclosures = new Map<string, boolean>();
export function readDisclosure(key: string): boolean | undefined { return disclosures.get(key); }
export function rememberDisclosure(key: string, open: boolean): void {
  disclosures.delete(key);
  disclosures.set(key, open);
  if (disclosures.size > 2000) disclosures.delete(disclosures.keys().next().value!);
}
const files = new Map<string, string>();
const scrolls = new Map<string, { top: number; following: boolean }>();
const fileKey = (project: string, path: string) => JSON.stringify([project, path]);

export function readDraft(project: string): string { return drafts.get(project) ?? ""; }
export function rememberDraft(project: string, text: string): void {
  if (text) drafts.set(project, text);
  else drafts.delete(project);
}
export function readFileDraft(project: string, path: string): string | null {
  return files.get(fileKey(project, path)) ?? null;
}
export function rememberFileDraft(project: string, path: string, text: string | null): void {
  const key = fileKey(project, path);
  if (text === null) files.delete(key);
  else files.set(key, text);
}
export function renameFileDraft(project: string, from: string, to: string): void {
  const text = readFileDraft(project, from);
  rememberFileDraft(project, from, null);
  if (text !== null) rememberFileDraft(project, to, text);
}
export function readScroll(key: string | undefined) { return key ? scrolls.get(key) : undefined; }
export function rememberScroll(key: string | undefined, viewport: HTMLElement): void {
  if (key) scrolls.set(key, { top: viewport.scrollTop, following: viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop <= 24 });
}
export function _resetWorkspaceMemoryForTests(): void { drafts.clear(); files.clear(); scrolls.clear(); disclosures.clear(); }
