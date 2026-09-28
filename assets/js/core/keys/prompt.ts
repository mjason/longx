// One text prompt for the commands that need a word from the person (a
// conversation's new name): a title, a label, the current value and what
// submitting does. Drawn by ui/keys/PromptDialog.
import { useSyncExternalStore } from "react";

export type PromptRequest = { title: string; label: string; value: string; submit: string; onSubmit: (value: string) => void };

let current: PromptRequest | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function openPrompt(request: PromptRequest): void {
  current = request;
  emit();
}

export function closePrompt(): void {
  current = null;
  emit();
}

export function usePrompt(): PromptRequest | null {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => current,
    () => current,
  );
}
