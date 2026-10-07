import { useEffect } from "react";
import type { AssistantRuntime } from "@assistant-ui/react";
import { readDraft, rememberDraft } from "@/core/workspaceMemory";

/** Text also survives disposal of an empty/inactive session. Attachments and
 * queues stay in their live session rather than being serialized or re-uploaded. */
export function useProjectDraft(projectId: string, threadId: string | undefined, runtime: AssistantRuntime): void {
  useEffect(() => {
    const composer = runtime.thread.composer;
    const key = JSON.stringify([projectId, threadId ?? null]);
    const scope = runtime.thread.getState().threadId;
    composer.setText(readDraft(key));
    // Runtime.thread is a moving binding. The old listener may see the next
    // thread's empty composer before React cleans it up; never erase its draft.
    const save = () => {
      if (runtime.thread.getState().threadId === scope) rememberDraft(key, composer.getState().text);
    };
    const unsubscribe = composer.subscribe(save);
    return () => { unsubscribe(); };
  }, [projectId, threadId, runtime]);

}
