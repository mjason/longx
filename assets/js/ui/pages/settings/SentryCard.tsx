// Settings → 请求记录 → 错误上报: the Sentry DSN (Longx.Sentry). Saving one
// turns reporting on — request exceptions, process crashes, the server's
// faults, failed turns —; clearing it turns reporting off; a test event
// proves the wiring.
import { useState } from "react";
import { toast } from "sonner";
import { useSentryActions, useSentryStatus } from "@/core/sentry";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.sentry;

export function SentryCard() {
  const status = useSentryStatus();
  const actions = useSentryActions();
  const [draft, setDraft] = useState("");
  const [result, setResult] = useState<string | null>(null);

  const save = async (dsn: string) => {
    try {
      await actions.setDsn.mutateAsync(dsn);
      setDraft("");
      toast.success(dsn ? s.saved : s.cleared);
    } catch (e) {
      toast.error((e as Error).message);
    }
  };

  const test = async () => {
    setResult(null);
    try {
      const r = await actions.test.mutateAsync();
      setResult(r.ok ? s.testOk(r.message) : s.testFailed(r.message));
    } catch (e) {
      setResult(s.testFailed((e as Error).message));
    }
  };

  return (
    <section className="flex flex-col gap-3" data-testid="section-sentry">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="text-base font-medium">{s.title}</h2>
        {status.data ? <Badge variant={status.data.enabled ? "default" : "outline"}>{status.data.enabled ? s.on : s.off}</Badge> : null}
      </div>
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      {status.isPending ? <Skeleton className="h-10 w-full" /> : null}
      {status.data ? (
        <>
          {status.data.dsn ? (
            <p className="text-muted-foreground text-xs">
              {s.current}: <code>{status.data.dsn}</code> · {s.environment}: {status.data.environment} · {s.release}: {status.data.release}
            </p>
          ) : null}
          <form
            className="flex flex-col gap-2 sm:flex-row sm:items-end"
            onSubmit={(e) => {
              e.preventDefault();
              if (draft.trim()) void save(draft.trim());
            }}
          >
            <div className="grid flex-1 gap-1">
              <Label htmlFor="sentry-dsn">DSN</Label>
              <Input id="sentry-dsn" value={draft} placeholder={s.placeholder} onChange={(e) => setDraft(e.target.value)} autoComplete="off" />
            </div>
            <Button type="submit" disabled={actions.setDsn.isPending || !draft.trim()}>{s.save}</Button>
            {status.data.enabled ? (
              <>
                <Button type="button" variant="outline" onClick={() => void test()} disabled={actions.test.isPending}>{s.test}</Button>
                <Button type="button" variant="ghost" className="text-destructive" onClick={() => void save("")} disabled={actions.setDsn.isPending}>{s.clear}</Button>
              </>
            ) : null}
          </form>
          {result ? <p className="text-muted-foreground text-xs">{result}</p> : null}
        </>
      ) : null}
    </section>
  );
}
