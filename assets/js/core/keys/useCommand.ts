// Registers a command while the component is mounted; the latest closures
// run, so a component registers once and its state stays current.
import { useEffect, useRef, useSyncExternalStore } from "react";
import { commands } from "./registry";

export function useCommand(id: string, run: () => void, available?: () => boolean): void {
  const latest = useRef({ run, available });
  latest.current = { run, available };
  useEffect(
    () =>
      commands.register({
        id,
        run: () => latest.current.run(),
        available: () => (latest.current.available ? latest.current.available() : true),
      }),
    [id],
  );
}

/** Re-renders when commands come and go (the which-key panel, the palette). */
export function useCommandsVersion(): number {
  return useSyncExternalStore(commands.subscribe, commands.version, commands.version);
}
