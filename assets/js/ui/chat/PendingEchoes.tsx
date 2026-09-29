// The echoes of what was sent and the view does not show yet
// (core/chat/pending): drawn after the messages, as user bubbles — faded,
// 发送中… under them, or 已插入 for a steer, in red with the reason when the
// send failed. Outside assistant-ui's message list on purpose: a message
// that appears there and then gives way to the server's item (another id at
// the same place) stays in the runtime's message repository as a phantom
// sibling — the branch picker read "2 / 2" under the next answer.
import { useChat } from "./ChatProvider";
import { t } from "@/ui/strings";

export function PendingEchoes() {
  const { echoes } = useChat();
  if (echoes.length === 0) return null;
  return (
    <div data-slot="aui_pending-echoes" className="mb-14 flex flex-col gap-y-6">
      {echoes.map((echo) => (
        <div
          key={echo.id}
          data-testid="pending-echo"
          data-pending={echo.kind}
          className="grid auto-rows-auto grid-cols-[minmax(72px,1fr)_auto] content-start gap-y-2 [&:where(>*)]:col-start-2"
        >
          {echo.images.length > 0 ? (
            <div className="col-start-2 flex flex-row flex-wrap justify-end gap-2">
              {echo.images.map((image, i) => (
                <img key={i} src={image} alt="" className="max-h-24 rounded-md object-cover" />
              ))}
            </div>
          ) : null}
          {echo.text ? (
            <div className={`col-start-2 min-w-0 ${echo.error ? "" : "opacity-60"}`}>
              <div className="bg-muted text-foreground rounded-xl px-4 py-2 wrap-break-word">
                <span className="whitespace-pre-wrap">{echo.text}</span>
              </div>
            </div>
          ) : null}
          <p className={`col-start-2 text-end text-xs ${echo.error ? "text-destructive" : "text-muted-foreground"}`} data-testid="pending-note">
            {echo.error ? t.sendFailed(echo.error) : echo.kind === "steer" ? t.steerPending : t.sending}
          </p>
        </div>
      ))}
    </div>
  );
}
