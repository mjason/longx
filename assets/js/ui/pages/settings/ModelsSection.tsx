// Settings → 模型: what a person sets day to day — which model new
// conversations, projects and sub-agents run on, at which reasoning level.
// The default model (a name: a tier by preference), the tiers and the
// aliases — each a chain of models, every one at its own level, the
// fallbacks as chips —, and web search, which goes two ways by model: the
// provider searches on its side (自带搜索), or Longx's web_search does with
// the search service's key (代搜). Where the models come from — endpoints,
// keys, windows, levels — is Settings → Provider (./ProvidersSection).
import { Plus, Trash2, X } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import {
  useAiActions,
  useDefaultModel,
  useModelAliases,
  useModelRows,
  useProviders,
  useSearchProviders,
  type ModelAlias,
  type ModelRow,
  type Provider,
} from "@/core/ai";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Select, SelectContent, SelectGroup, SelectItem, SelectLabel, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";
import { SearchBadge, searchesItself } from "./ProvidersSection";

const s = t.ai;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));
const NONE = "__none";

type Link = { slug: string; effort: string };

/** What the page needs of a model: its levels, its default level, whether it searches on its side. */
type Facts = Map<string, { levels: string[]; effort: string | null; searches: boolean }>;

export function ModelsSection() {
  const models = useModelRows();
  const providers = useProviders();
  const aliases = useModelAliases();
  if (models.isPending || providers.isPending || aliases.isPending) return <Skeleton className="h-24 w-full" data-testid="section-models" />;
  if (models.isError) return <p className="text-destructive text-sm">{models.error.message}</p>;
  const rows = models.data.filter((m) => m.slug);
  const byId = new Map<string, Provider>((providers.data ?? []).map((p) => [p.id, p]));
  const facts: Facts = new Map(
    rows.map((m) => [m.slug!, { levels: m.reasoningLevels, effort: m.reasoningEffort, searches: searchesItself(m, byId.get(m.providerId)) }]),
  );
  const all = aliases.data ?? [];
  return (
    <div className="flex flex-col gap-6" data-testid="section-models">
      <p className="text-muted-foreground text-sm">{s.modelsHint}</p>
      <DefaultModelCard rows={rows} aliases={all} facts={facts} />
      <ChainsCard
        testId="model-tiers"
        title={s.tiers}
        hint={s.tiersHint}
        chains={all.filter((a) => a.builtin)}
        slugs={rows.map((m) => m.slug!)}
        facts={facts}
      />
      <ChainsCard
        testId="model-aliases"
        title={s.aliases}
        hint={s.aliasesOnlyHint}
        chains={all.filter((a) => !a.builtin)}
        slugs={rows.map((m) => m.slug!)}
        facts={facts}
        adding
      />
      <SearchCard rows={rows} facts={facts} />
    </div>
  );
}

function Card({ testId, title, hint, children }: { testId: string; title: string; hint?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg border p-4" data-testid={testId}>
      <h2 className="text-base font-medium">{title}</h2>
      {hint ? <p className="text-muted-foreground mt-1 text-sm">{hint}</p> : null}
      <div className="mt-3">{children}</div>
    </section>
  );
}

function DefaultModelCard({ rows, aliases, facts }: { rows: ModelRow[]; aliases: ModelAlias[]; facts: Facts }) {
  const current = useDefaultModel();
  const actions = useAiActions();
  if (!current.data) return null;
  const tiers = aliases.filter((a) => a.builtin);
  const custom = aliases.filter((a) => !a.builtin);
  const pick = (name: string) => actions.setDefaultModel.mutate(name, { onSuccess: () => toast.success(s.defaultModelSaved), onError: fail });
  // what it runs on now: the model, at the level its tier gave it, else the model's default
  const chain = aliases.find((a) => a.name === current.data.name);
  const slug = current.data.slug;
  const level = slug ? ((chain && chain.models[0] === slug ? chain.efforts?.[0] : null) ?? facts.get(slug)?.effort ?? null) : null;
  return (
    <Card testId="default-model" title={s.defaultModel} hint={s.defaultModelHint}>
      <div className="flex flex-wrap items-center gap-3">
        <Select value={current.data.name} onValueChange={pick}>
          <SelectTrigger className="h-10 w-72 max-w-full" aria-label={s.defaultModel}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectGroup>
              <SelectLabel>{s.defaultModelTiers}</SelectLabel>
              {tiers.map((a) => (
                <SelectItem key={a.name} value={a.name}>
                  {a.name} · {a.label}
                  {a.models[0] ? ` → ${a.models[0]}` : ` → ${s.defaultModelBase}`}
                </SelectItem>
              ))}
            </SelectGroup>
            {custom.length > 0 ? (
              <SelectGroup>
                <SelectLabel>{s.defaultModelAliases}</SelectLabel>
                {custom.map((a) => (
                  <SelectItem key={a.name} value={a.name}>
                    {a.name}
                    {a.models[0] ? ` → ${a.models[0]}` : ""}
                  </SelectItem>
                ))}
              </SelectGroup>
            ) : null}
            <SelectGroup>
              <SelectLabel>{s.defaultModelModels}</SelectLabel>
              {rows.map((m) => (
                <SelectItem key={m.slug!} value={m.slug!}>
                  {m.slug}
                </SelectItem>
              ))}
            </SelectGroup>
          </SelectContent>
        </Select>
        <span className="text-muted-foreground font-mono text-sm">{slug ? s.defaultModelNow(slug, level) : s.defaultModelUnresolved}</span>
      </div>
    </Card>
  );
}

function ChainsCard({
  testId,
  title,
  hint,
  chains,
  slugs,
  facts,
  adding = false,
}: {
  testId: string;
  title: string;
  hint: string;
  chains: ModelAlias[];
  slugs: string[];
  facts: Facts;
  adding?: boolean;
}) {
  const actions = useAiActions();
  const [name, setName] = useState("");
  // the whole chain, each model beside its level ("" = the model's default)
  const save = (alias: string, links: Link[]) => {
    const kept = links.filter((l) => l.slug);
    actions.setModelAlias.mutate(
      { name: alias, models: kept.map((l) => l.slug), efforts: kept.map((l) => l.effort) },
      { onSuccess: () => toast.success(s.aliasSaved), onError: fail },
    );
  };
  const add = () => {
    const alias = name.trim();
    if (!alias || slugs.length === 0) return;
    actions.setModelAlias.mutate({ name: alias, models: [slugs[0]!], efforts: [""] }, { onSuccess: () => (setName(""), toast.success(s.aliasSaved)), onError: fail });
  };
  return (
    <Card testId={testId} title={title} hint={hint}>
      <div className="divide-y">
        {chains.map((a) => (
          <ChainRow
            key={a.name}
            alias={a}
            slugs={slugs}
            facts={facts}
            onSave={(links) => save(a.name, links)}
            onRemove={a.builtin ? undefined : () => actions.deleteModelAlias.mutate(a.name, { onError: fail })}
          />
        ))}
      </div>
      {adding ? (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder={s.aliasNamePlaceholder} aria-label={s.aliasAdd} className="w-40" />
          <Button size="sm" variant="outline" onClick={add} disabled={!name.trim() || actions.setModelAlias.isPending}>
            <Plus className="size-4" /> {s.aliasAdd}
          </Button>
        </div>
      ) : null}
    </Card>
  );
}

function LevelSelect({ slug, value, label, facts, onChange, compact = false }: { slug: string; value: string; label: string; facts: Facts; onChange: (v: string) => void; compact?: boolean }) {
  const levels = slug ? (facts.get(slug)?.levels ?? []) : [];
  return (
    <Select value={value || NONE} onValueChange={(v) => onChange(v === NONE ? "" : v)} disabled={levels.length === 0}>
      <SelectTrigger className={`font-mono text-xs ${compact ? "h-6 w-auto gap-1 border-0 bg-transparent px-1" : "h-9 w-24"}`} aria-label={label}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={NONE}>{s.aliasLevelDefault}</SelectItem>
        {levels.map((level) => (
          <SelectItem key={level} value={level} className="font-mono">
            {level}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function ChainRow({ alias, slugs, facts, onSave, onRemove }: { alias: ModelAlias; slugs: string[]; facts: Facts; onSave: (links: Link[]) => void; onRemove?: () => void }) {
  const links: Link[] = alias.models.map((slug, i) => ({ slug, effort: alias.efforts?.[i] ?? "" }));
  const primary = links[0] ?? { slug: "", effort: "" };
  const fallbacks = links.slice(1);
  const primaryName = `${alias.name} ${s.aliasPrimary}`;
  const setPrimary = (patch: Partial<Link>) => {
    // another model starts at its own default level
    const next: Link = patch.slug !== undefined ? { slug: patch.slug, effort: "" } : { ...primary, ...patch };
    onSave(next.slug ? [next, ...fallbacks] : fallbacks);
  };
  const setFallback = (i: number, effort: string) => onSave([primary, ...fallbacks.map((f, j) => (j === i ? { ...f, effort } : f))]);
  const unused = slugs.filter((slug) => !links.some((l) => l.slug === slug));
  return (
    <div className="grid items-center gap-x-4 gap-y-2 py-3 sm:grid-cols-[5.5rem_minmax(0,1fr)_2rem]" data-testid={`alias-${alias.name}`}>
      <div className="flex items-baseline gap-2">
        <span className="font-mono text-sm font-medium">{alias.name}</span>
        {alias.label !== alias.name ? <span className="text-muted-foreground text-xs">{alias.label}</span> : null}
      </div>
      <div className="flex flex-wrap items-center gap-2 sm:flex-nowrap">
        <Select value={primary.slug || NONE} onValueChange={(v) => setPrimary({ slug: v === NONE ? "" : v })}>
          <SelectTrigger className="h-9 w-44 max-w-full font-mono text-xs" aria-label={primaryName}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {alias.builtin ? <SelectItem value={NONE}>{s.aliasNone}</SelectItem> : null}
            {slugs.map((slug) => (
              <SelectItem key={slug} value={slug} className="font-mono">
                {slug}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <LevelSelect slug={primary.slug} value={primary.effort} label={s.aliasLevel(primaryName)} facts={facts} onChange={(effort) => setPrimary({ effort })} />
        {primary.slug ? <SearchBadge own={facts.get(primary.slug)?.searches ?? false} /> : null}
      </div>
      {onRemove ? (
        <Button size="icon" variant="ghost" className="text-destructive size-8 sm:row-span-2" onClick={onRemove} aria-label={`${s.aliasRemove} ${alias.name}`}>
          <Trash2 className="size-4" />
        </Button>
      ) : (
        <span className="hidden sm:row-span-2 sm:block" />
      )}
      {/* the fallbacks on a line of their own under the model: chips, each with its level */}
      <div className="flex flex-wrap items-center gap-1 sm:col-start-2">
        <span className="text-muted-foreground mr-1 text-xs">{s.fallbacks}</span>
        {fallbacks.map((f, i) => (
          <span key={f.slug} className="bg-muted inline-flex items-center gap-1 rounded-full py-0.5 pr-1 pl-2.5 font-mono text-xs whitespace-nowrap" data-testid={`fallback-${f.slug}`}>
            {f.slug}
            <LevelSelect compact slug={f.slug} value={f.effort} label={s.fallbackLevel(alias.name, f.slug)} facts={facts} onChange={(effort) => setFallback(i, effort)} />
            <SearchBadge own={facts.get(f.slug)?.searches ?? false} />
            <button
              type="button"
              aria-label={s.removeFallback(alias.name, f.slug)}
              className="text-muted-foreground hover:text-foreground rounded-full p-0.5"
              onClick={() => onSave(links.filter((l) => l.slug !== f.slug))}
            >
              <X className="size-3" />
            </button>
          </span>
        ))}
        {primary.slug && unused.length > 0 ? (
          <Select value="" onValueChange={(slug) => onSave([...links, { slug, effort: "" }])}>
            <SelectTrigger className="text-primary h-7 w-auto gap-1 border-dashed px-2 text-xs" aria-label={s.addFallbackLabel(alias.name)}>
              <SelectValue placeholder={s.addFallback} />
            </SelectTrigger>
            <SelectContent>
              {unused.map((slug) => (
                <SelectItem key={slug} value={slug} className="font-mono">
                  {slug}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        ) : null}
        {fallbacks.length === 0 && !(primary.slug && unused.length > 0) ? <span className="text-muted-foreground text-xs">{s.searchNoModels}</span> : null}
      </div>
    </div>
  );
}

function SearchCard({ rows, facts }: { rows: ModelRow[]; facts: Facts }) {
  const own = rows.filter((m) => facts.get(m.slug!)?.searches);
  const ours = rows.filter((m) => !facts.get(m.slug!)?.searches);
  return (
    <Card testId="web-search" title={s.search} hint={s.searchCardHint}>
      <div className="divide-y">
        <div className="grid gap-2 py-3 sm:grid-cols-[7rem_minmax(0,1fr)]" data-testid="search-own">
          <div>
            <SearchBadge own />
          </div>
          <div className="flex flex-col gap-2">
            <p className="text-muted-foreground text-sm">{s.searchOwnHint}</p>
            <ModelChips rows={own} />
          </div>
        </div>
        <div className="grid gap-2 py-3 sm:grid-cols-[7rem_minmax(0,1fr)]" data-testid="search-ours">
          <div>
            <Badge variant="outline" className="border-primary/40 text-primary">
              {s.searchOursLong}
            </Badge>
          </div>
          <div className="flex flex-col gap-2">
            <p className="text-muted-foreground text-sm">{s.searchOursHint}</p>
            <ModelChips rows={ours} />
            <SearchKey needed={ours.length > 0} />
          </div>
        </div>
      </div>
    </Card>
  );
}

function ModelChips({ rows }: { rows: ModelRow[] }) {
  if (rows.length === 0) return <span className="text-muted-foreground text-xs">{s.searchNoModels}</span>;
  return (
    <div className="flex flex-wrap gap-1">
      {rows.map((m) => (
        <span key={m.id} className="bg-muted rounded-full px-2.5 py-0.5 font-mono text-xs">
          {m.slug}
        </span>
      ))}
    </div>
  );
}

/** The search service's key (Tavily): set, kept unseen, replaced when typed. */
function SearchKey({ needed }: { needed: boolean }) {
  const search = useSearchProviders();
  const actions = useAiActions();
  const [key, setKey] = useState("");
  const row = search.data?.find((r) => r.default) ?? search.data?.[0];
  if (!row) return null;
  return (
    <form
      className="flex flex-col gap-1.5"
      data-testid="search-provider"
      onSubmit={(e) => {
        e.preventDefault();
        if (!key) return;
        actions.setSearchKey.mutate({ id: row.id, apiKey: key }, { onSuccess: () => (toast.success(s.saved), setKey("")), onError: fail });
      }}
    >
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="font-medium">{row.name}</span>
        {row.hasApiKey ? <Badge variant="secondary">{s.apiKeySet}</Badge> : <Badge variant="destructive">{s.apiKeyMissing}</Badge>}
        {!row.hasApiKey && needed ? <span className="text-warning text-xs">{s.searchKeyNeeded}</span> : null}
      </div>
      <Label htmlFor="sp-key" className="sr-only">
        {s.apiKey}
      </Label>
      <div className="flex max-w-md gap-2">
        <Input id="sp-key" type="password" autoComplete="off" aria-label={s.apiKey} placeholder={row.hasApiKey ? s.keepKey : s.apiKey} value={key} onChange={(e) => setKey(e.target.value)} className="min-w-0 flex-1 font-mono" />
        <Button type="submit" disabled={!key || actions.setSearchKey.isPending}>
          {t.save}
        </Button>
      </div>
    </form>
  );
}
