import { Loader2, ShieldAlert } from "lucide-react";
import { useMemo } from "react";
import { contextUsage } from "@/core/chat/thread";
import { useModels } from "@/core/projects";
import { ContextDisplay } from "@/ui/components/assistant-ui/elements/context-display";
import {
  ModelSelectorContent,
  ModelSelectorEffort,
  ModelSelectorEmpty,
  ModelSelectorGroup,
  ModelSelectorItem,
  ModelSelectorList,
  ModelSelectorRoot,
  ModelSelectorSearch,
  ModelSelectorTrigger,
  type ModelOption,
} from "@/ui/components/assistant-ui/elements/model-selector";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";
import { ModePicker } from "./ModePicker";

/**
 * Left of the composer rail (Codex's layout): the access mode the next
 * turn runs with, and what the turn is doing right now.
 */
export function ComposerLeading() {
  const { state, mode, setMode, disabledReason, thread } = useChat();
  return (
    <div
      className="text-muted-foreground flex min-w-0 items-center gap-2 text-xs"
      data-testid="turn-bar"
    >
      <ModePicker
        mode={mode}
        onChange={setMode}
        disabled={disabledReason !== null}
        started={thread !== undefined}
      />
      {state === "running" ? (
        <span className="flex items-center gap-1">
          <Loader2 className="size-3.5 animate-spin" /> {t.turnRunning}
        </span>
      ) : state === "approval" ? (
        <span className="flex items-center gap-1 text-amber-600 dark:text-amber-400">
          <ShieldAlert className="size-3.5" /> {t.awaitingApproval}
        </span>
      ) : null}
    </div>
  );
}

/**
 * Right of the rail, before send: how full the model's context is (codex's
 * token usage against the window it was told) and the model the next turn
 * uses (null = the thread's current) with its reasoning level — the Model
 * selector element, standalone: the choice is ours to send, not a model
 * context registration.
 */
export function ComposerTrailing() {
  const { thread, view, model, setModel, effort, setEffort, defaultModelId } =
    useChat();
  const models = useModels();
  const rows = useMemo(
    () => (models.data ?? []).filter((m) => m.slug),
    [models.data],
  );
  // the thread's model (a new chat: the project's default, else the global one), unless another was picked
  const current = thread
    ? (thread.modelSlug ?? rows.find((m) => m.default)?.slug ?? null)
    : (defaultModelId && rows.find((m) => m.id === defaultModelId)?.slug) ||
      rows.find((m) => m.default)?.slug ||
      null;
  const selected = model ?? current ?? undefined;
  const row = rows.find((m) => m.slug === selected);
  // the level in force: the thread's own while it stays on its model, else the model's default
  const inForce =
    (thread && (model === null || model === thread.modelSlug)
      ? thread.reasoningEffort
      : null) ??
    row?.reasoningEffort ??
    undefined;
  const shownEffort = effort ?? inForce;

  const options = useMemo<ModelOption[]>(
    () =>
      rows.map((m) => ({
        id: m.slug!,
        name: m.slug!,
        description: `${providerName(m.provider)} · ${formatWindow(m.contextWindow)}`,
        keywords: [providerName(m.provider), m.name],
        ...(m.reasoningLevels.length > 0
          ? {
              efforts: m.reasoningLevels.map((level) => ({
                id: level,
                name: effortLabel(level),
              })),
            }
          : {}),
      })),
    [rows],
  );
  const groups = useMemo(() => {
    const byProvider = new Map<string, ModelOption[]>();
    rows.forEach((m, i) => {
      const key = providerName(m.provider);
      byProvider.set(key, [...(byProvider.get(key) ?? []), options[i]!]);
    });
    return [...byProvider.entries()];
  }, [rows, options]);
  // one object per token-usage update: the ring stores what it is given and
  // re-syncs (a render-phase setState) whenever the identity changes
  const usage = useMemo(() => contextUsage(view), [view.tokenUsage]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <>
      {usage ? (
        <ContextDisplay.Ring
          modelContextWindow={usage.modelContextWindow}
          usage={usage.usage}
          resetKey={view.threadId}
          labels={t.context}
          className="h-7"
        />
      ) : null}
      <ModelSelectorRoot
        models={options}
        value={selected}
        onValueChange={(slug) => setModel(slug === current ? null : slug)}
        effort={shownEffort}
        onEffortChange={setEffort}
      >
        <ModelSelectorTrigger
          variant="ghost"
          size="sm"
          aria-label={t.model}
          className="h-7 gap-1 px-2 font-mono text-xs"
          data-testid="model-picker"
        >
          {row ? (
            <span className="flex min-w-0 items-center gap-1.5">
              <span className="truncate">{row.slug}</span>
              {shownEffort ? (
                <span className="text-muted-foreground font-sans">
                  {effortLabel(shownEffort)}
                </span>
              ) : null}
            </span>
          ) : (
            <span className="text-muted-foreground">{t.defaultModel}</span>
          )}
        </ModelSelectorTrigger>
        <ModelSelectorContent
          align="end"
          searchable={rows.length > 6}
          className="w-72"
        >
          {rows.length > 6 ? (
            <ModelSelectorSearch placeholder={t.searchModels} />
          ) : null}
          <ModelSelectorList>
            <ModelSelectorEmpty>{t.noModelFound}</ModelSelectorEmpty>
            {groups.map(([name, group]) => (
              <ModelSelectorGroup key={name} heading={name}>
                {group.map((option) => (
                  <ModelSelectorItem
                    key={option.id}
                    model={option}
                    className="font-mono text-xs"
                  />
                ))}
              </ModelSelectorGroup>
            ))}
          </ModelSelectorList>
          <ModelSelectorEffort label={t.reasoningLevel} />
        </ModelSelectorContent>
      </ModelSelectorRoot>
    </>
  );
}

/** a level as the rail names it (codex's known efforts; anything else as is) */
export function effortLabel(level: string): string {
  return t.effortLevels[level] ?? level;
}

function formatWindow(tokens: number | null | undefined): string {
  if (!tokens) return "";
  if (tokens >= 1_000_000) return `${Math.round(tokens / 100_000) / 10}M`;
  return `${Math.round(tokens / 1000)}k`;
}

function providerName(provider: unknown): string {
  return provider && typeof provider === "object" && "name" in provider
    ? String(provider.name)
    : "";
}
