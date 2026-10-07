import { createContext, useCallback, useContext, useEffect, useId, useState, type ReactNode } from "react";
import { useBlocker } from "react-router";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Button } from "@/ui/components/ui/button";
import { useSettingsCopy } from "./copy";

const DraftContext = createContext<((id: string, dirty: boolean) => void) | null>(null);

/** Explicit draft registration: successful unrelated mutations cannot clear a draft. */
export function useSettingsDraft(dirty: boolean) {
  const register = useContext(DraftContext);
  const id = useId();
  useEffect(() => {
    register?.(id, dirty);
    return () => register?.(id, false);
  }, [register, id, dirty]);
}

export function SettingsDraftProvider({ children }: { children: ReactNode }) {
  const s = useSettingsCopy();
  const [drafts, setDrafts] = useState<Set<string>>(() => new Set());
  const register = useCallback((id: string, dirty: boolean) => {
    setDrafts((previous) => {
      if (previous.has(id) === dirty) return previous;
      const next = new Set(previous);
      if (dirty) next.add(id); else next.delete(id);
      return next;
    });
  }, []);
  const dirty = drafts.size > 0;
  const blocker = useBlocker(({ currentLocation, nextLocation }) =>
    dirty && (currentLocation.pathname !== nextLocation.pathname || currentLocation.search !== nextLocation.search));
  useEffect(() => {
    if (!dirty) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);
  return (
    <DraftContext.Provider value={register}>
      {children}
      <Dialog open={blocker.state === "blocked"} onOpenChange={(open) => { if (!open && blocker.state === "blocked") blocker.reset(); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>{s.unsaved}</DialogTitle><DialogDescription>{s.unsavedHint}</DialogDescription></DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => blocker.state === "blocked" && blocker.reset()}>{s.stay}</Button>
            <Button onClick={() => blocker.state === "blocked" && blocker.proceed()}>{s.discard}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </DraftContext.Provider>
  );
}
