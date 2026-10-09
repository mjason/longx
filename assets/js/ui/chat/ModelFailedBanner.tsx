import { useTranslation } from "react-i18next";
// A turn that ended because its model gave up (the kernel's `model_failed`:
// the retries spent, the chain exhausted) — the person picks another model
// and the thread goes on with 继续 on it, for this and later turns.
import { useEffect, useState } from "react";
import { AlertTriangle, Copy } from "lucide-react";
import { toast } from "sonner";
import { sendMessage } from "@/core/api";
import { unwrap, useModels } from "@/core/projects";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { Button } from "@/ui/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";
import { copyText } from "@/ui/lib/clipboard";

type TurnError = {
  message?: string; code?: string; model?: string; provider?: string;
  httpStatus?: number | null;
  source?: "http" | "stream" | "transport" | "limiter";
};

export function ModelFailedBanner() {
    useTranslation();
  const { view, thread, state, setModel } = useChat();
  const models = useModels();
  const [picked, setPicked] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState(false);
  const progress = view.progress;
  const retrying = progress?.kind === "retry" || progress?.kind === "compactionRetry";
  const raw = view.turn?.["error"];
  const turnError = typeof raw === "string" ? { message: raw } : raw as TurnError | undefined;
  const failed = state === "idle" && view.turn?.["status"] === "failed";
  const last = view.items.at(-1);
  const compactError: TurnError | null = state === "idle" && last?.type === "contextCompactionFailed" && last.turnId === view.turn?.["id"]
    ? { message: String(last.error ?? ""), httpStatus: last.httpStatus as number | null | undefined, source: last.source as TurnError["source"] }
    : null;
  const error: TurnError | null | undefined = retrying
    ? { ...progress, message: progress.message || progress.name }
    : compactError ?? (failed ? turnError : null);
  useEffect(() => {
    setOpen(false);
    setPicked(null);
  }, [view.turn?.["id"]]);
  useEffect(() => {
    if (!error?.message) setOpen(false);
  }, [error?.message]);
  if (!error?.message) return null;

  const s = t.modelFailed;
  const choices = (models.data ?? []).filter((m) => m.slug && m.slug !== error.model);
  const status = typeof error.httpStatus === "number" ? `HTTP ${error.httpStatus}` : t.requestError.unknown;
  const source = error.source ? t.requestError.sources[error.source] : null;
  const details = [
    `${t.requestError.status}: ${status}`,
    source ? `${t.requestError.source}: ${source}` : null,
    error.model ? `Model: ${error.model}` : null,
    error.provider ? `Provider: ${error.provider}` : null,
    error.message,
  ].filter(Boolean).join("\n\n");

  const go = async () => {
    if (!picked || !thread) return;
    setBusy(true);
    try {
      unwrap(await sendMessage({ input: { threadId: thread.id, text: s.continueText, model: picked } }));
      setModel(picked);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <span className="shrink-0" data-testid="request-error-status">
        <PopoverTrigger asChild>
          <button type="button" className={`flex min-w-0 max-w-[28vw] items-center gap-1 text-xs hover:underline ${retrying ? "text-warning" : "text-destructive"}`} aria-label={t.requestError.details}>
            <AlertTriangle className="size-3 shrink-0" />
            <span className="truncate">{retrying ? t.requestError.details : t.requestError.failed}</span>
          </button>
        </PopoverTrigger>
      </span>
      <PopoverContent side="top" align="start" className="max-h-[70vh] w-96 max-w-[calc(100vw-2rem)] overflow-y-auto text-xs" data-testid="request-error-details">
        <div className="flex items-center justify-between gap-2">
          <p className="font-medium">{t.requestError.title}</p>
          <Button type="button" variant="ghost" size="sm" className="h-7 gap-1 text-xs" onClick={async () => {
            try { await copyText(details); toast.success(t.requestError.copied, { position: "top-right" }); } catch (e) { toast.error((e as Error).message, { position: "top-right" }); }
          }}><Copy className="size-3" />{t.requestError.copy}</Button>
        </div>
        <p className="mt-2">{t.requestError.status}: <span className="font-mono">{status}</span></p>
        {source ? <p className="text-muted-foreground mt-1">{source}</p> : null}
        <pre className="bg-muted mt-2 max-h-48 select-text overflow-auto rounded p-2 text-[11px] whitespace-pre-wrap break-all">{error.message}</pre>
        {!retrying && error.code === "model_failed" && thread ? <div className="mt-3">
          <p className="mb-2">{s.title(error.model ?? "?")}</p>
          <div className="flex flex-wrap items-center gap-2">
          <Select value={picked ?? undefined} onValueChange={setPicked}>
            <SelectTrigger className="h-9 w-56" aria-label={s.pick}>
              <SelectValue placeholder={s.pick} />
            </SelectTrigger>
            <SelectContent>
              {choices.map((m) => (
                <SelectItem key={m.slug!} value={m.slug!}>{m.slug}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Button size="sm" variant="outline" disabled={!picked || busy} onClick={() => void go()}>
            {s.go}
          </Button>
          </div>
        </div> : null}
      </PopoverContent>
    </Popover>
  );
}
