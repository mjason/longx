import { useEffect } from "react";
import { useBlocker } from "react-router";
import type { AssistantRuntime } from "@assistant-ui/react";
import { toast } from "sonner";
import { readDraft, rememberDraft } from "@/core/workspaceMemory";
import { t } from "@/ui/strings";

/** Text is retained per project. In-flight attachments/queues must not vanish
 * with a runtime, so navigation out of that project is explicitly held. */
export function useProjectDraft(projectId: string, slug: string, threadId: string | undefined, runtime: AssistantRuntime): void {
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

  const blocker = useBlocker(({ currentLocation, nextLocation }) => {
    const prefix = `/p/${slug}`;
    const inside = (path: string) => path === prefix || path.startsWith(prefix + "/");
    if (!inside(currentLocation.pathname) || inside(nextLocation.pathname)) return false;
    const composer = runtime.thread.composer.getState();
    return composer.attachments.length > 0 || composer.queue.length > 0;
  });
  useEffect(() => {
    if (blocker.state === "blocked") {
      toast.warning(t.switchingProjectBlocked);
      blocker.reset();
    }
  }, [blocker]);
}
