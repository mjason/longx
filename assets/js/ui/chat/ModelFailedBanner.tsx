// A turn that ended because its model gave up (the kernel's `model_failed`:
// the retries spent, the chain exhausted) — the person picks another model
// and the thread goes on with 继续 on it, for this and later turns.
import { useState } from "react";
import { toast } from "sonner";
import { sendMessage } from "@/ash_rpc";
import { unwrap, useModels } from "@/core/projects";
import { Alert, AlertDescription } from "@/ui/components/ui/alert";
import { Button } from "@/ui/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

type TurnError = { message?: string; code?: string; model?: string };

export function ModelFailedBanner() {
  const { view, thread, state, setModel } = useChat();
  const models = useModels();
  const [picked, setPicked] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const error = (view.turn?.["error"] as TurnError | undefined) ?? null;
  const failed = state === "idle" && view.turn?.["status"] === "failed" && error?.code === "model_failed";
  if (!failed || !thread) return null;

  const s = t.modelFailed;
  const choices = (models.data ?? []).filter((m) => m.slug && m.slug !== error.model);

  const go = async () => {
    if (!picked) return;
    setBusy(true);
    try {
      unwrap(await sendMessage({ fields: ["id"], input: { threadId: thread.id, text: s.continueText, model: picked } }));
      setModel(picked);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Alert variant="destructive" className="m-3 w-auto" data-testid="model-failed">
      <AlertDescription className="flex flex-col gap-2">
        <span>{s.title(error.model ?? "?")}</span>
        {error.message ? <span className="text-xs opacity-80">{error.message}</span> : null}
        <span className="flex flex-wrap items-center gap-2">
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
        </span>
      </AlertDescription>
    </Alert>
  );
}
