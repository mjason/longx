// The edge above a long thread's window: how many earlier turns wait there,
// and the way to show them — assistant-ui's "windowed history" shape
// (`useExternalStoreRuntime` renders whatever `messages` holds, so the window is
// the tail of the array and showing more is widening it). The reader's place
// is kept by pinning the message that was first: the browser does not anchor a
// scroller sitting at the top, and the turns that come in above are laid out
// over several frames (content-visibility placeholders, lazy shiki and KaTeX).
import { useAuiState } from "@assistant-ui/react";
import { createContext, useContext, useEffect, useRef } from "react";
import { HISTORY_WINDOW, type ThreadHistory } from "@/core/chat/runtime";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";

export const HistoryContext = createContext<ThreadHistory | null>(null);

const SETTLE_MS = 1200;

export function HistoryEdge() {
  const history = useContext(HistoryContext);
  const ref = useRef<HTMLDivElement>(null);
  // the messages are rendered by index, so the message that was first is found
  // again by its id once the earlier ones sit above it
  const messages = useAuiState((s) => s.thread.messages);
  const latest = useRef(messages);
  latest.current = messages;
  const frame = useRef<number | null>(null);
  useEffect(() => () => { if (frame.current !== null) cancelAnimationFrame(frame.current); }, []);

  const hidden = history?.hiddenTurns ?? 0;
  if (!history || hidden <= 0) return null;

  const show = (turns: number | "all") => {
    const viewport = ref.current?.closest<HTMLElement>('[data-slot="aui_thread-viewport"]');
    const firstId = latest.current[0]?.id;
    if (viewport && firstId) {
      const roots = () => viewport.querySelectorAll<HTMLElement>('[data-slot="aui_message-group"] > [data-role]');
      const top = (el: Element) => el.getBoundingClientRect().top - viewport.getBoundingClientRect().top;
      const wanted = roots()[0] ? top(roots()[0]!) : 0;
      const until = performance.now() + SETTLE_MS;
      const pin = () => {
        const index = latest.current.findIndex((m) => m.id === firstId);
        const el = index >= 0 ? roots()[index] : undefined;
        if (el) viewport.scrollTop += top(el) - wanted;
        frame.current = performance.now() < until ? requestAnimationFrame(pin) : null;
      };
      if (frame.current !== null) cancelAnimationFrame(frame.current);
      frame.current = requestAnimationFrame(pin);
    }
    history.showEarlier(turns);
  };

  return (
    <div
      ref={ref}
      data-testid="history-edge"
      className="text-muted-foreground mb-6 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-xs"
    >
      <span>{t.history.hidden(hidden)}</span>
      <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={() => show(HISTORY_WINDOW)}>
        {t.history.more(Math.min(HISTORY_WINDOW, hidden))}
      </Button>
      <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={() => show("all")}>
        {t.history.all}
      </Button>
    </div>
  );
}
