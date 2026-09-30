import { useTranslation } from "react-i18next";
// The edge above a long thread's window: what waits above the items the view
// holds (the server sends the tail — how many turns whole, how many items of
// the turn it cut), and the way to fetch it, a page at a time or all of it.
// The reader's place is kept by pinning the message that was first — its
// bottom edge, since a window that cut a turn grows that message at its top
// when the turn's earlier items come in. The browser does not anchor a
// scroller sitting at the top; the height of the whole viewport is no
// measure either (messages are drawn by index over content-visibility
// placeholders, whose remembered sizes shuffle when the list shifts); and
// the new part is laid out over several frames (lazy shiki and KaTeX), so
// for a while after the page is in the message is put back every frame.
import { useAuiState } from "@assistant-ui/react";
import { createContext, useContext, useEffect, useRef } from "react";
import type { ThreadHistory } from "@/core/chat/runtime";
import { HISTORY_PAGE } from "@/core/chat/thread";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";

export const HistoryContext = createContext<ThreadHistory | null>(null);

const SETTLE_MS = 1200;

export function HistoryEdge() {
    useTranslation();
  const history = useContext(HistoryContext);
  const ref = useRef<HTMLDivElement>(null);
  // the messages are rendered by index, so the message that was first is found
  // again by its id once the earlier ones sit above it
  const messages = useAuiState((s) => s.thread.messages);
  const latest = useRef(messages);
  latest.current = messages;
  const frame = useRef<number | null>(null);
  useEffect(() => () => { if (frame.current !== null) cancelAnimationFrame(frame.current); }, []);

  const hidden = history?.hiddenItems ?? 0;
  if (!history || hidden <= 0) return null;

  const show = (count: number | "all") => {
    const viewport = ref.current?.closest<HTMLElement>('[data-slot="aui_thread-viewport"]');
    const firstId = latest.current[0]?.id;
    const roots = () => viewport?.querySelectorAll<HTMLElement>('[data-slot="aui_message-group"] > [data-role]') ?? [];
    const bottom = (el: Element) => el.getBoundingClientRect().bottom - (viewport?.getBoundingClientRect().top ?? 0);
    const wanted = roots()[0] ? bottom(roots()[0]!) : 0;
    // the items arrive from the server: the pinning starts when they are in
    const pin = () => {
      if (!viewport || !firstId) return;
      const until = performance.now() + SETTLE_MS;
      const step = () => {
        const index = latest.current.findIndex((m) => m.id === firstId);
        const el = index >= 0 ? roots()[index] : undefined;
        if (el) viewport.scrollTop += bottom(el) - wanted;
        frame.current = performance.now() < until ? requestAnimationFrame(step) : null;
      };
      if (frame.current !== null) cancelAnimationFrame(frame.current);
      frame.current = requestAnimationFrame(step);
    };
    void history.showEarlier(count).then(pin, () => {});
  };

  return (
    <div
      ref={ref}
      data-testid="history-edge"
      className="text-muted-foreground mb-6 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-xs"
    >
      {history.hiddenTurns > 0 ? <span>{t.history.hidden(history.hiddenTurns)}</span> : null}
      {history.partial > 0 ? <span>{t.history.partial(history.partial)}</span> : null}
      {history.loading ? (
        <span>{t.history.loading}</span>
      ) : (
        <>
          <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={() => show(HISTORY_PAGE)}>
            {t.history.more(Math.min(HISTORY_PAGE, hidden))}
          </Button>
          <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={() => show("all")}>
            {t.history.all}
          </Button>
        </>
      )}
    </div>
  );
}
