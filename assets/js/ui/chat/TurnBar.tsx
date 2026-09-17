import { Loader2, ShieldAlert } from "lucide-react";
import { useMemo } from "react";
import { contextUsage } from "@/core/chat/thread";
import { useModels } from "@/core/projects";
import { useModelAliases } from "@/core/ai";
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
import { Button } from "@/ui/components/ui/button";
import { shellPick, shellPresent } from "@/ui/shell/longxShell";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

/**
 * Left of the composer rail: what the turn is doing right now (running,
 * or waiting on the person to act).
 */
export function ComposerLeading() {
  const { state, view } = useChat();
  return (
    <div
      className="text-muted-foreground flex min-w-0 items-center gap-2 text-xs"
      data-testid="turn-bar"
    >
      {state === "running" ? (
        <span className="flex items-center gap-1">
          <Loader2 className="size-3.5 animate-spin" /> {t.turnRunning}
        </span>
      ) : state === "waiting" ? (
        <span className="flex items-center gap-1 text-amber-600 dark:text-amber-400">
          <ShieldAlert className="size-3.5" />{" "}
          {t.awaitingAction}
        </span>
      ) : null}
    </div>
  );
}

/**
 * Right of the rail, before send: how full the model's context is (the last
 * turn's token usage against the model's window) and the model the next turn
 * uses (null = the thread's current) with its reasoning level — the Model
 * selector element, standalone: the choice is ours to send, not a model
 * context registration.
 */
export function ComposerTrailing() {
  const { thread, view, model, setModel, effort, setEffort, defaultModelId, definitionModel } =
    useChat();
  const models = useModels();
  const aliases = useModelAliases();
  const rows = useMemo(
    () => (models.data ?? []).filter((m) => m.slug),
    [models.data],
  );
  // the model in force when nobody picks one: the thread's own, else the description's
  // (it overrides the default silently otherwise — a turn went to a provider the rail
  // never named); a new chat the project's default, else the global one
  const described = definitionModel?.model ?? null;
  const current = thread
    ? (thread.modelSlug ?? described ?? rows.find((m) => m.default)?.slug ?? null)
    : described ||
      (defaultModelId && rows.find((m) => m.id === defaultModelId)?.slug) ||
      rows.find((m) => m.default)?.slug ||
      null;
  const selected = model ?? current ?? undefined;
  // a tier or alias answers with its first model's levels
  const aliasRow = aliases.data?.find((a) => a.name === selected);
  const row = rows.find((m) => m.slug === (aliasRow ? aliasRow.models[0] : selected));
  // the level in force: the thread's own while it stays on its model, the description's, else the model's default
  const inForce =
    (thread && (model === null || model === thread.modelSlug)
      ? thread.reasoningEffort
      : null) ??
    (model === null && described && described === current ? definitionModel?.effort : null) ??
    row?.reasoningEffort ??
    undefined;
  const shownEffort = effort ?? inForce;

  const options = useMemo<ModelOption[]>(
    () => [
      ...(aliases.data ?? []).map((a) => ({
        id: a.name,
        name: a.label === a.name ? a.name : `${a.name}（${a.label}）`,
        description: a.models.length ? a.models.join(" → ") : t.ai.aliasNone,
        provider: t.ai.aliases,
        efforts: (rows.find((m) => m.slug === a.models[0])?.reasoningLevels ?? []).map((level) => ({
          id: level,
          name: effortLabel(level),
        })),
      })),
      ...rows.map((m) => ({
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
    ],
    [rows, aliases.data],
  );
  const groups = useMemo(() => {
    const aliasCount = aliases.data?.length ?? 0;
    const byProvider = new Map<string, ModelOption[]>();
    rows.forEach((m, i) => {
      const key = providerName(m.provider);
      byProvider.set(key, [...(byProvider.get(key) ?? []), options[aliasCount + i]!]);
    });
    const tiers: [string, ModelOption[]][] = aliasCount ? [[t.ai.aliases, options.slice(0, aliasCount)]] : [];
    return [...tiers, ...byProvider.entries()];
  }, [rows, options, aliases.data]);
  // one object per token-usage update: the ring stores what it is given and
  // re-syncs (a render-phase setState) whenever the identity changes
  const usage = useMemo(() => contextUsage(view), [view.tokenUsage]); // eslint-disable-line react-hooks/exhaustive-deps

  // inside a native shell the popover gives way to the shell's own list
  // (a bottom sheet): the model, then — when it has them — its levels
  const pickNatively = async () => {
    const slug = await shellPick({
      title: t.model,
      sections: groups.map(([name, group]) => ({
        label: name,
        options: group.map((o) => ({ id: o.id, label: o.name, detail: o.description })),
      })),
      selected: selected ?? null,
    });
    if (slug === null) return;
    setModel(slug === current ? null : slug);
    const picked = rows.find((m) => m.slug === slug);
    if (!picked || picked.reasoningLevels.length === 0) return;
    const level = await shellPick({
      title: t.reasoningLevel,
      sections: [{ options: picked.reasoningLevels.map((l) => ({ id: l, label: effortLabel(l) })) }],
      selected: (slug === selected ? shownEffort : null) ?? picked.reasoningEffort ?? null,
    });
    if (level !== null) setEffort(level);
  };

  const label = row ? (
    <span className="flex min-w-0 items-center gap-1.5">
      <span className="truncate">{row.slug}</span>
      {shownEffort ? (
        <span className="text-muted-foreground hidden sm:inline">
          {effortLabel(shownEffort)}
        </span>
      ) : null}
    </span>
  ) : (
    <span className="text-muted-foreground">{t.defaultModel}</span>
  );

  const ring = usage ? (
    <ContextDisplay.Ring
      modelContextWindow={usage.modelContextWindow}
      usage={usage.usage}
      resetKey={view.threadId}
      labels={t.context}
      className="h-7"
    />
  ) : null;

  if (shellPresent()) {
    return (
      <>
        {ring}
        <Button
          variant="ghost"
          size="sm"
          aria-label={t.model}
          className="h-7 max-w-[42vw] gap-1 px-2 font-mono text-xs sm:max-w-none"
          data-testid="model-picker"
          onClick={() => void pickNatively()}
        >
          {label}
        </Button>
      </>
    );
  }

  return (
    <>
      {ring}
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
          className="h-7 max-w-[42vw] gap-1 px-2 font-mono text-xs sm:max-w-none"
          data-testid="model-picker"
        >
          {label}
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

/** a level as the rail names it: the provider's own word (none, low, high, …), never translated */
export function effortLabel(level: string): string {
  return level;
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
