import { createContext, useContext } from "react";
import type { CodexRuntime } from "@/core/chat/runtime";

export const ChatContext = createContext<CodexRuntime | null>(null);

export function useChat(): CodexRuntime {
  const ctx = useContext(ChatContext);
  if (!ctx) throw new Error("useChat outside the thread screen");
  return ctx;
}
