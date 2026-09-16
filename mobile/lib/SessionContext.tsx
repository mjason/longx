import { createContext, useContext } from "react";
import type { Session } from "./session";

export type SessionState = {
  session: Session | null;
  setSession: (session: Session | null) => void;
};

export const SessionContext = createContext<SessionState | null>(null);

export function useSession(): SessionState {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useSession outside SessionContext");
  return ctx;
}
