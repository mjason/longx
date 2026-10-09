import { useTranslation } from "react-i18next";
import { Loader2, ShieldAlert } from "lucide-react";
import { lazy, Suspense, useMemo } from "react";
import { contextUsage } from "@/core/chat/thread";
import { progressLabel } from "./progressLabel";
import { useModels } from "@/core/projects";
import { useDefaultModel, useModelAliases, type ModelAlias } from "@/core/ai";
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
import { nativePickerAvailable, shellPick } from "@/ui/shell/longxShell";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

const JobWorkStatus = lazy(() => import("./ThreadJobs").then(module => ({ default: module.JobWorkStatus })));

/**
 * Left of the composer rail: what the turn is doing right now (running,
 * or waiting on the person to act).
 */
export function ComposerLeading() {
    useTranslation();
  const { state, view } = useChat();
  return (
    <div
      className="text-muted-foreground flex min-w-0 items-center gap-2 text-xs"
      data-testid="turn-bar"
    >
      {state === "running" || state === "compacting" ? (
        <span className="flex items-center gap-1">
          <Loader2 className="size-3.5 animate-spin" />{" "}
          {progressLabel(view.progress, t.turnRunning)}
        </span>
      ) : state === "waiting" ? (
        <span className="flex items-center gap-1 text-amber-600 dark:text-amber-400">
          <ShieldAlert className="size-3.5" />{" "}
          {t.awaitingAction}
        </span>
      ) : null}
      <Suspense fallback={null}><JobWorkStatus /></Suspense>
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
    useTranslation();
  const { thread, view, model, setModel, effort, setEffort, defaultModelId, definitionModel } =
    useChat();
  const models = useModels();
  const aliases = useModelAliases();
  const globalDefault = useDefaultModel();
  const rows = useMemo(
    () => (models.data ?? []).filter((m) => m.slug),
    [models.data],
  );
  // the model in force when nobody picks one: the thread's own, else the description's
  // (it overrides the default silently otherwise — a turn went to a provider the rail
  // never named); a new chat the project's default, else the global one
  const described = definitionModel?.model ?? null;
  // the global default is a name (a tier by preference): what the rail shows when nothing else stands
  const fallback = globalDefault.data?.name ?? rows.find((m) => m.default)?.slug ?? null;
  const current = thread
    ? (thread.modelSlug ?? described ?? fallback)
    : described ||
      (defaultModelId && rows.find((m) => m.id === defaultModelId)?.slug) ||
      fallback;
  const selected = model ?? current ?? undefined;
  // a tier or alias stands for its first model; an unmapped tier for the base
  // model (what the global default resolves to, else the row flagged default)
  const base = globalDefault.data?.slug ?? rows.find((m) => m.default)?.slug;
  const aliasRow = aliases.data?.find((a) => a.name === selected);
  const concrete = aliasRow ? (aliasRow.models[0] ?? base) : selected;
  const row = rows.find((m) => m.slug === concrete);
  // the level in force: the thread's own while it stays on its model, the description's,
  // else — a tier or alias — the level the tier gave its model, else the model's default
  const ownLevel =
    (thread && (model === null || model === thread.modelSlug) ? thread.reasoningEffort : null) ??
    (model === null && described && described === current ? definitionModel?.effort : null) ??
    null;
  const tierLevel = aliasRow ? (aliasRow.efforts?.[0] ?? row?.reasoningEffort ?? null) : null;
  const inForce = ownLevel ?? (aliasRow ? tierLevel : row?.reasoningEffort) ?? undefined;
  const shownEffort = effort ?? inForce;
  // nothing picked on a tier: it follows the tier's own level (the first level item)
  const followsTier = aliasRow !== undefined && effort === null && ownLevel === null;

  const options = useMemo<ModelOption[]>(
    () => [
      ...(aliases.data ?? []).map((a) => ({
        id: a.name,
        name: a.label === a.name ? a.name : `${a.name}（${a.label}）`,
        description: a.models.length ? a.models.join(" → ") : t.ai.aliasNone,
        provider: t.ai.aliases,
        efforts: tierEfforts(a, rows.find((m) => m.slug === (a.models[0] ?? base))),
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
    [rows, aliases.data, base],
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
  // One object per token-usage update, including post-compaction invalidation.
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
    // a tier or alias stands for its first model: that model's levels, the tier's own first
    const pickedAlias = aliases.data?.find((a) => a.name === slug);
    const picked = rows.find((m) => m.slug === (pickedAlias ? (pickedAlias.models[0] ?? base) : slug));
    if (!picked || picked.reasoningLevels.length === 0) return;
    const levels = pickedAlias ? tierEfforts(pickedAlias, picked) : picked.reasoningLevels.map((l) => ({ id: l, name: effortLabel(l) }));
    const preselected = slug === selected ? (followsTier ? FOLLOW_TIER : shownEffort) : pickedAlias ? FOLLOW_TIER : picked.reasoningEffort;
    const level = await shellPick({
      title: t.reasoningLevel,
      sections: [{ options: levels.map((l) => ({ id: l.id, label: l.name })) }],
      selected: preselected ?? null,
    });
    if (level !== null) setEffort(level === FOLLOW_TIER ? null : level);
  };

  // a tier or alias shows its name and, muted, the model it stands for right now
  const label = row ? (
    <span className="flex min-w-0 items-center gap-1.5">
      <span className="truncate">{aliasRow ? aliasRow.name : row.slug}</span>
      {aliasRow ? <span className="text-muted-foreground hidden truncate sm:inline">{row.slug}</span> : null}
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

  if (nativePickerAvailable()) {
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
        effort={followsTier ? FOLLOW_TIER : shownEffort}
        onEffortChange={(level) => setEffort(level === FOLLOW_TIER ? null : level)}
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
          className="w-80 max-w-[calc(100vw-2rem)]"
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

// the level item that follows a tier's own level (nothing picked)
const FOLLOW_TIER = "__tier";

/** A tier's levels: its first model's, with "follow the tier" (its own level, else the model's default) first. */
function tierEfforts(alias: ModelAlias, first: { reasoningLevels: string[]; reasoningEffort?: string | null } | undefined) {
  const levels = first?.reasoningLevels ?? [];
  if (levels.length === 0) return [];
  const own = alias.efforts?.[0] ?? first?.reasoningEffort ?? null;
  return [
    { id: FOLLOW_TIER, name: own ? t.ai.followTier(effortLabel(own)) : t.ai.followTierDefault },
    ...levels.map((level) => ({ id: level, name: effortLabel(level) })),
  ];
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
