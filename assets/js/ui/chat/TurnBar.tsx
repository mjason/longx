import { Loader2, ShieldAlert } from "lucide-react";
import type { TurnState } from "@/core/chat/runtime";
import { useModels } from "@/core/projects";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { t } from "@/ui/strings";



/**
 * The thin bar above the composer: what the turn is doing, and which model
 * the next turn uses (null = whatever the thread runs now).
 */
export function TurnBar({ state, threadModel, model, onModel }: { state: TurnState; threadModel: string | null; model: string | null; onModel: (slug: string | null) => void }) {
  const models = useModels();
  const current = threadModel ?? models.data?.find((m) => m.default)?.slug ?? null;
  return (
    <div className="text-muted-foreground flex items-center gap-3 px-3 py-1 text-xs" data-testid="turn-bar">
      <span className="flex min-w-0 flex-1 items-center gap-1.5">
        {state === "running" ? (
          <>
            <Loader2 className="size-3.5 animate-spin" /> {t.turnRunning}
          </>
        ) : state === "approval" ? (
          <>
            <ShieldAlert className="text-amber-500 size-3.5" /> {t.awaitingApproval}
          </>
        ) : null}
      </span>
      <Select value={model ?? "__current"} onValueChange={(v) => onModel(v === "__current" ? null : v)}>
        <SelectTrigger size="sm" aria-label={t.model} className="h-7 gap-1 border-0 bg-transparent px-2 font-mono text-xs shadow-none dark:bg-transparent dark:hover:bg-accent" data-testid="model-picker">
          {/* the trigger shows the slug only; the items carry the explanation */}
          <SelectValue>{model ?? current ?? t.defaultModel}</SelectValue>
        </SelectTrigger>
        <SelectContent align="end">
          <SelectItem value="__current" className="font-mono text-xs">
            {current ?? t.defaultModel} · {t.threadModel}
          </SelectItem>
          {(models.data ?? [])
            .filter((m) => m.slug)
            .map((m) => (
              <SelectItem key={m.id} value={m.slug!} className="font-mono text-xs">
                {m.slug} <span className="text-muted-foreground ml-1 font-sans">{providerName(m.provider)}</span>
              </SelectItem>
            ))}
        </SelectContent>
      </Select>
    </div>
  );
}

function providerName(provider: unknown): string {
  return provider && typeof provider === "object" && "name" in provider ? String(provider.name) : "";
}
