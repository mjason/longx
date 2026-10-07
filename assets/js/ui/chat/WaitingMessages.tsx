import { lazy, Suspense, useRef, useState } from "react";
import { toast } from "sonner";
import { useChat } from "./ChatProvider";
import { t } from "@/ui/strings";

// No inbox to draw on most pages: load its detailed UI only when needed.
const WaitingView = lazy(() => import("./WaitingMessagesView").then(module => ({ default: module.WaitingMessagesView })));
export { WaitingMessagesView } from "./WaitingMessagesView";

export function WaitingMessages() {
  const { view, releaseWaiting, releaseWaitingBatch } = useChat();
  const [busy, setBusy] = useState(false);
  const sending = useRef(false);
  const release = async (action: () => Promise<void>) => {
    if (sending.current) return;
    sending.current = true;
    setBusy(true);
    try {
      await action();
    } catch (error) {
      toast.error(error instanceof Error ? error.message : String(error));
    } finally {
      sending.current = false;
      setBusy(false);
    }
  };
  if (!view.waiting.items.length) return null;
  return <Suspense fallback={<span className="px-2 text-xs text-muted-foreground">{t.waitingCount(view.waiting.items.length)}</span>}>
    <WaitingView waiting={view.waiting} busy={busy}
      onRelease={(id) => void release(() => releaseWaiting(id))}
      onReleaseAll={() => void release(releaseWaitingBatch)} />
  </Suspense>;
}
