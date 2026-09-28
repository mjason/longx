// The commands the space menu, the command palette, the buttons' hints and
// (later) a native client's menus all run: registered by the part of the
// page that can carry them out, while it is on screen. The last
// registration of an id wins until it goes (a tab's own save over the
// page's); `available` says whether it can run now (no "stop" without a
// running turn), and the menu offers only what can.

export type Command = {
  id: string;
  run: () => void;
  available?: () => boolean;
};

export type Registry = {
  register: (command: Command) => () => void;
  available: (id: string) => boolean;
  /** runs it when it can; false when there is nothing to run */
  run: (id: string) => boolean;
  subscribe: (listener: () => void) => () => void;
  /** changes with every registration, for React's useSyncExternalStore */
  version: () => number;
};

export function createRegistry(): Registry {
  const stacks = new Map<string, Command[]>();
  const listeners = new Set<() => void>();
  let version = 0;
  const changed = () => {
    version += 1;
    listeners.forEach((l) => l());
  };
  const top = (id: string) => {
    const stack = stacks.get(id);
    return stack && stack.length > 0 ? stack[stack.length - 1] : undefined;
  };
  const available = (id: string) => {
    const command = top(id);
    if (!command) return false;
    try {
      return command.available ? command.available() : true;
    } catch {
      return false;
    }
  };
  return {
    register(command) {
      const stack = stacks.get(command.id) ?? [];
      stack.push(command);
      stacks.set(command.id, stack);
      changed();
      return () => {
        const current = stacks.get(command.id) ?? [];
        const i = current.lastIndexOf(command);
        if (i >= 0) current.splice(i, 1);
        if (current.length === 0) stacks.delete(command.id);
        changed();
      };
    },
    available,
    run(id) {
      if (!available(id)) return false;
      top(id)!.run();
      return true;
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    version: () => version,
  };
}

/** The page's registry. */
export const commands = createRegistry();
