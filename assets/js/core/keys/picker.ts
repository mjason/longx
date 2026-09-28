// One picker for the commands that choose something — a project, a
// conversation, a tab, a file, a model: a title, the items (or a search the
// items come from as the person types) and what picking one does. The page
// draws it (ui/keys/PickerDialog); the commands only ask.
import { useSyncExternalStore } from "react";

export type PickerItem = { id: string; label: string; detail?: string; keywords?: string };

export type PickerRequest = {
  title: string;
  placeholder?: string;
  /** a fixed list, filtered as typed */
  items?: PickerItem[];
  /** or: the items for what is typed (the file search) */
  search?: (query: string) => Promise<PickerItem[]>;
  onPick: (item: PickerItem) => void;
};

let current: PickerRequest | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function openPicker(request: PickerRequest): void {
  current = request;
  emit();
}

export function closePicker(): void {
  current = null;
  emit();
}

export function usePicker(): PickerRequest | null {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => current,
    () => current,
  );
}
