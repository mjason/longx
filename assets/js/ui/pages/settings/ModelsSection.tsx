// Settings → 模型与 Provider: every provider as a card — its endpoint, key
// status and last error, then its models with the default marked — and the
// search provider's key. Adding and editing happen in dialogs; deleting
// asks first.
import {
  CheckCircle2,
  ChevronDown,
  ExternalLink,
  MoreHorizontal,
  Plus,
  Star,
} from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";
import { relativeTime } from "@/core/format";
import {
  useAiActions,
  useModelRows,
  usePresets,
  useProviders,
  useReviewSettings,
  useSearchProviders,
  type ModelInput,
  type ModelRow,
  type Preset,
  type Provider,
  type ProviderInput,
} from "@/core/ai";
import { effortLabel } from "@/ui/chat/TurnBar";
import {
  ModelPicker,
  type PickableModel,
} from "@/ui/components/assistant-ui/elements/model-picker";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/ui/components/ui/dropdown-menu";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/ui/components/ui/select";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

const s = t.ai;
const fail = (e: unknown) =>
  toast.error(e instanceof Error ? e.message : String(e));

// what the section's dialogs can be doing: choosing a template, filling one
// in, or the free-form provider form (new or editing a row)
type Editing =
  | { kind: "choose" }
  | { kind: "preset"; preset: Preset }
  | { kind: "custom"; provider: Provider | null }
  | null;

export function ModelsSection() {
  const providers = useProviders();
  const models = useModelRows();
  const presets = usePresets();
  const [editing, setEditing] = useState<Editing>(null);
  if (providers.isPending || models.isPending)
    return <Skeleton className="h-24 w-full" data-testid="section-models" />;
  if (providers.isError)
    return (
      <p className="text-destructive text-sm">{providers.error.message}</p>
    );
  if (models.isError)
    return <p className="text-destructive text-sm">{models.error.message}</p>;
  return (
    <div className="flex flex-col gap-8" data-testid="section-models">
      <section className="flex flex-col gap-3">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-base font-medium">{s.providers}</h2>
          <Button size="sm" onClick={() => setEditing({ kind: "choose" })}>
            <Plus className="size-4" /> {s.addProvider}
          </Button>
        </div>
        <p className="text-muted-foreground text-sm">{s.providersHint}</p>
        {providers.data.map((p) => (
          <ProviderCard
            key={p.id}
            provider={p}
            models={models.data.filter((m) => m.providerId === p.id)}
            preset={
              presets.data?.find((preset) => preset.providerId === p.id) ?? null
            }
            onEdit={() => setEditing({ kind: "custom", provider: p })}
            onAddFromPreset={(preset) => setEditing({ kind: "preset", preset })}
          />
        ))}
      </section>
      <ReviewModelCard models={models.data} />
      <SearchProviderCard />
      {editing?.kind === "choose" ? (
        <PresetChooser
          presets={presets.data ?? []}
          onPick={(preset) =>
            setEditing(
              preset
                ? { kind: "preset", preset }
                : { kind: "custom", provider: null },
            )
          }
          onClose={() => setEditing(null)}
        />
      ) : null}
      {editing?.kind === "preset" ? (
        <PresetDialog
          preset={editing.preset}
          onClose={() => setEditing(null)}
        />
      ) : null}
      {editing?.kind === "custom" ? (
        <ProviderDialog
          provider={editing.provider}
          onClose={() => setEditing(null)}
        />
      ) : null}
    </div>
  );
}

/** The first step of "add": a template (the facts filled in) or the free form. */
function PresetChooser({
  presets,
  onPick,
  onClose,
}: {
  presets: Preset[];
  onPick: (preset: Preset | null) => void;
  onClose: () => void;
}) {
  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{s.chooseTemplate}</DialogTitle>
          <DialogDescription>{s.chooseTemplateHint}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-2 sm:grid-cols-2">
          {presets.map((preset) => (
            <button
              key={preset.slug}
              type="button"
              onClick={() => onPick(preset)}
              className="hover:bg-accent flex min-h-16 min-w-0 flex-col items-start gap-1 rounded-lg border p-3 text-start transition-colors"
            >
              <span className="flex w-full items-center justify-between gap-2">
                <span className="font-medium">{preset.name}</span>
                {preset.installed ? (
                  <Badge variant="secondary">{s.presetInstalled}</Badge>
                ) : null}
              </span>
              <span className="text-muted-foreground w-full truncate font-mono text-xs" title={preset.baseUrl}>
                {preset.baseUrl}
              </span>
              <span className="text-muted-foreground text-xs">
                {preset.models.map((m) => m.upstreamId).join(" · ")}
              </span>
            </button>
          ))}
          <button
            type="button"
            onClick={() => onPick(null)}
            className="hover:bg-accent flex min-h-16 flex-col items-start gap-1 rounded-lg border border-dashed p-3 text-start transition-colors"
          >
            <span className="font-medium">{s.custom}</span>
            <span className="text-muted-foreground text-xs">
              {s.customHint}
            </span>
          </button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

const formatWindow = (tokens: number) =>
  tokens >= 1_000_000
    ? `${Math.round(tokens / 100_000) / 10}M`
    : `${Math.round(tokens / 1000)}k`;

/**
 * A template in one step: the key (unless the provider is already there),
 * the models to add — the registry's model-picker list as a checklist,
 * recommended ones pre-checked, installed ones left out — and which becomes
 * the default.
 */
function PresetDialog({
  preset,
  onClose,
}: {
  preset: Preset;
  onClose: () => void;
}) {
  const actions = useAiActions();
  const providers = useProviders();
  // an installed provider without a key still wants one
  const needsKey =
    !preset.installed ||
    !providers.data?.find((p) => p.id === preset.providerId)?.hasApiKey;
  const candidates = preset.models.filter((m) => !m.installed);
  const [apiKey, setApiKey] = useState("");
  const [chosen, setChosen] = useState<string[]>(
    candidates.filter((m) => m.recommended).map((m) => m.upstreamId),
  );
  const [makeDefault, setMakeDefault] = useState("__keep");
  const rows: PickableModel[] = candidates.map((m) => ({
    id: m.upstreamId,
    name: m.upstreamId,
    family: preset.name,
    context: formatWindow(m.contextWindow),
    capabilities: [
      ...(m.image ? [s.image] : []),
      ...(m.reasoningLevels.length > 0
        ? [`${m.reasoningLevels.map(effortLabel).join(" / ")}`]
        : []),
    ],
  }));
  const toggle = (id: string) =>
    setChosen((ids) =>
      ids.includes(id)
        ? ids.filter((x) => x !== id)
        : candidates
            .filter((m) => m.upstreamId === id || ids.includes(m.upstreamId))
            .map((m) => m.upstreamId),
    );
  const submit = (e: FormEvent) => {
    e.preventDefault();
    actions.applyPreset.mutate(
      {
        slug: preset.slug,
        ...(apiKey ? { apiKey } : {}),
        models: chosen,
        ...(makeDefault !== "__keep" && chosen.includes(makeDefault)
          ? { makeDefault }
          : {}),
      },
      { onSuccess: () => (toast.success(s.saved), onClose()), onError: fail },
    );
  };
  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <form onSubmit={submit} className="flex flex-col gap-4">
          <DialogHeader>
            <DialogTitle>
              {preset.installed
                ? s.presetMoreTitle(preset.name)
                : s.presetTitle(preset.name)}
            </DialogTitle>
            <DialogDescription className="font-mono text-xs break-all">
              {preset.baseUrl}
            </DialogDescription>
          </DialogHeader>
          {needsKey ? (
            <Field
              id="ps-key"
              label={s.apiKey}
              hint={s.presetKeyHint(preset.keyEnv)}
            >
              <Input
                id="ps-key"
                type="password"
                autoComplete="off"
                value={apiKey}
                onChange={(e) => setApiKey(e.target.value)}
                className="font-mono"
              />
            </Field>
          ) : null}
          <div className="flex flex-wrap gap-3 text-xs">
            <a
              href={preset.keyUrl}
              target="_blank"
              rel="noreferrer"
              className="text-primary inline-flex items-center gap-1 underline-offset-4 hover:underline"
            >
              {s.getKey} <ExternalLink className="size-3" />
            </a>
            <a
              href={preset.docsUrl}
              target="_blank"
              rel="noreferrer"
              className="text-muted-foreground inline-flex items-center gap-1 underline-offset-4 hover:underline"
            >
              {s.presetDocs} <ExternalLink className="size-3" />
            </a>
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>{s.presetModels}</Label>
            {rows.length > 0 ? (
              <ModelPicker
                models={rows}
                selectedIds={chosen}
                onToggle={toggle}
                className="max-w-none"
              />
            ) : (
              <p className="text-muted-foreground text-sm">
                {s.presetAllInstalled}
              </p>
            )}
          </div>
          {chosen.length > 0 ? (
            <Field id="ps-default" label={s.defaultModel}>
              <Select value={makeDefault} onValueChange={setMakeDefault}>
                <SelectTrigger id="ps-default" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__keep">{s.keepDefault}</SelectItem>
                  {chosen.map((id) => (
                    <SelectItem key={id} value={id} className="font-mono">
                      {id}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          ) : null}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              {t.cancel}
            </Button>
            <Button
              type="submit"
              disabled={
                actions.applyPreset.isPending ||
                (chosen.length === 0 && preset.installed)
              }
            >
              {s.add}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function ProviderCard({
  provider,
  models,
  preset,
  onEdit,
  onAddFromPreset,
}: {
  provider: Provider;
  models: ModelRow[];
  preset: Preset | null;
  onEdit: () => void;
  onAddFromPreset: (preset: Preset) => void;
}) {
  const actions = useAiActions();
  const [adding, setAdding] = useState<ModelRow | "new" | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  // the template this provider came from still has models to offer
  const missing = preset?.models.some((m) => !m.installed) ? preset : null;
  return (
    <div className="rounded-lg border" data-testid={`provider-${provider.id}`}>
      <div className="flex items-start justify-between gap-3 p-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium">{provider.name}</span>
            <Badge variant="outline">{s.kinds[provider.kind]}</Badge>
            {provider.hasApiKey ? (
              <Badge variant="secondary">{s.apiKeySet}</Badge>
            ) : (
              <Badge variant="destructive">{s.apiKeyMissing}</Badge>
            )}
          </div>
          <p className="text-muted-foreground mt-1 truncate font-mono text-xs">
            {provider.baseUrl}
          </p>
          {provider.lastError ? (
            <p className="text-destructive mt-1 text-xs">
              {s.lastError}: {provider.lastError}
            </p>
          ) : provider.lastCheckedAt ? (
            <p className="text-muted-foreground mt-1 text-xs">
              {s.lastChecked(relativeTime(provider.lastCheckedAt))}
            </p>
          ) : null}
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              className="size-8 shrink-0"
              aria-label={`${provider.name} 的操作`}
            >
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onSelect={onEdit}>
              {s.editProvider}
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => setAdding("new")}>
              {s.addModel}
            </DropdownMenuItem>
            {missing ? (
              <DropdownMenuItem onSelect={() => onAddFromPreset(missing)}>
                {s.addFromPreset}
              </DropdownMenuItem>
            ) : null}
            <DropdownMenuItem
              variant="destructive"
              onSelect={() => setConfirmDelete(true)}
            >
              {s.deleteProvider}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <ul className="divide-y border-t">
        {models.length === 0 ? (
          <li className="text-muted-foreground px-3 py-2 text-sm">
            {s.noModels}
          </li>
        ) : null}
        {models.map((m) => (
          <ModelRowView key={m.id} model={m} onEdit={() => setAdding(m)} />
        ))}
        <li className="px-3 py-2">
          <Button variant="ghost" size="sm" onClick={() => setAdding("new")}>
            <Plus className="size-4" /> {s.addModel}
          </Button>
        </li>
      </ul>
      {adding ? (
        <ModelDialog
          provider={provider}
          model={adding === "new" ? null : adding}
          onClose={() => setAdding(null)}
        />
      ) : null}
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {s.deleteProviderTitle(provider.name)}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {s.deleteProviderHint}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() =>
                actions.deleteProvider.mutate(provider.id, {
                  onSuccess: () => toast.success(s.deleted),
                  onError: fail,
                })
              }
            >
              {t.delete}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function ModelRowView({
  model,
  onEdit,
}: {
  model: ModelRow;
  onEdit: () => void;
}) {
  const actions = useAiActions();
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [checked, setChecked] = useState<{
    ok: boolean;
    latencyMs: number | null;
    error: string | null;
  } | null>(null);
  const check = () =>
    actions.checkModel.mutate(model.id, {
      onSuccess: (r) => {
        setChecked(r);
        if (r.ok) toast.success(s.checkOk(r.latencyMs ?? 0));
        else toast.error(s.checkFailed(r.error ?? ""));
      },
      onError: fail,
    });
  return (
    <li
      className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-sm"
      data-testid={`model-${model.id}`}
    >
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-2">
          <span className="font-mono text-xs">
            {model.slug ?? model.upstreamId}
          </span>
          {model.default ? (
            <Badge>
              <Star className="size-3" /> {s.default}
            </Badge>
          ) : null}
        </span>
        <span className="text-muted-foreground text-xs">
          {model.name} · {model.upstreamId}
          {model.contextWindow ? ` · ${formatWindow(model.contextWindow)}` : ""}
          {model.reasoningLevels.length > 0
            ? ` · ${model.reasoningLevels.map(effortLabel).join(" / ")}`
            : ""}
          {model.reasoningEffort
            ? ` · ${s.default} ${effortLabel(model.reasoningEffort)}`
            : ""}
        </span>
        {checked ? (
          <span
            className={`text-xs ${checked.ok ? "text-success" : "text-destructive"}`}
          >
            {checked.ok ? (
              <>
                <CheckCircle2 className="mr-1 inline size-3" />
                {s.checkOk(checked.latencyMs ?? 0)}
              </>
            ) : (
              s.checkFailed(checked.error ?? "")
            )}
          </span>
        ) : null}
      </div>
      <div className="flex items-center gap-1">
        <Button
          variant="outline"
          size="sm"
          className="h-7"
          onClick={check}
          disabled={actions.checkModel.isPending}
        >
          {s.check}
        </Button>
        {!model.default ? (
          <Button
            variant="outline"
            size="sm"
            className="h-7"
            onClick={() =>
              actions.makeDefault.mutate(model.id, { onError: fail })
            }
          >
            {s.makeDefault}
          </Button>
        ) : null}
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              className="size-7"
              aria-label={`${model.name} 的操作`}
            >
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onSelect={onEdit}>{s.editModel}</DropdownMenuItem>
            <DropdownMenuItem
              variant="destructive"
              onSelect={() => setConfirmDelete(true)}
            >
              {s.deleteModel}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {s.deleteModelTitle(model.name)}
            </AlertDialogTitle>
            <AlertDialogDescription>{s.deleteModelHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() =>
                actions.deleteModel.mutate(model.id, {
                  onSuccess: () => toast.success(s.deleted),
                  onError: fail,
                })
              }
            >
              {t.delete}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </li>
  );
}

const slugOf = (name: string) =>
  name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

function ProviderDialog({
  provider,
  onClose,
}: {
  provider: Provider | null;
  onClose: () => void;
}) {
  const actions = useAiActions();
  const [form, setForm] = useState({
    name: provider?.name ?? "",
    slug: provider?.slug ?? "",
    baseUrl: provider?.baseUrl ?? "",
    apiKey: "",
    kind: provider?.kind ?? "openai_compatible",
    supportsHostedWebSearch: provider?.supportsHostedWebSearch ?? false,
    timeoutS: String(
      Math.round((provider?.requestTimeoutMs ?? 600_000) / 1000),
    ),
    concurrency: provider?.maxConcurrentRequests
      ? String(provider.maxConcurrentRequests)
      : "",
  });
  const set = <K extends keyof typeof form>(k: K, v: (typeof form)[K]) =>
    setForm((f) => ({ ...f, [k]: v }));
  const busy =
    actions.createProvider.isPending || actions.updateProvider.isPending;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    const common = {
      name: form.name.trim(),
      baseUrl: form.baseUrl.trim(),
      kind: form.kind as Provider["kind"],
      supportsHostedWebSearch: form.supportsHostedWebSearch,
      requestTimeoutMs: Math.max(1, Number(form.timeoutS) || 600) * 1000,
      maxConcurrentRequests: form.concurrency ? Number(form.concurrency) : null,
      ...(form.apiKey ? { apiKey: form.apiKey } : {}),
    };
    const done = {
      onSuccess: () => (toast.success(s.saved), onClose()),
      onError: fail,
    };
    if (provider)
      actions.updateProvider.mutate({ id: provider.id, input: common }, done);
    else
      actions.createProvider.mutate(
        {
          ...common,
          slug: form.slug.trim() || slugOf(form.name),
        } as ProviderInput,
        done,
      );
  };
  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <form onSubmit={submit} className="flex flex-col gap-4">
          <DialogHeader>
            <DialogTitle>
              {provider ? s.editProvider : s.addProvider}
            </DialogTitle>
          </DialogHeader>
          <Field id="pv-name" label={s.name}>
            <Input
              id="pv-name"
              value={form.name}
              onChange={(e) => set("name", e.target.value)}
              required
            />
          </Field>
          {!provider ? (
            <Field id="pv-slug" label={s.slug} hint={s.slugHint}>
              <Input
                id="pv-slug"
                value={form.slug}
                placeholder={slugOf(form.name)}
                onChange={(e) => set("slug", e.target.value)}
                className="font-mono"
              />
            </Field>
          ) : null}
          <Field id="pv-url" label={s.baseUrl}>
            <Input
              id="pv-url"
              type="url"
              value={form.baseUrl}
              placeholder="https://api.deepseek.com/v1"
              onChange={(e) => set("baseUrl", e.target.value)}
              required
              className="font-mono"
            />
          </Field>
          <Field
            id="pv-key"
            label={s.apiKey}
            hint={provider?.hasApiKey ? s.keepKey : undefined}
          >
            <Input
              id="pv-key"
              type="password"
              autoComplete="off"
              value={form.apiKey}
              onChange={(e) => set("apiKey", e.target.value)}
              className="font-mono"
            />
          </Field>
          <Field id="pv-kind" label={s.kind} hint={s.kindHint}>
            <Select
              value={form.kind}
              onValueChange={(v) => set("kind", v as Provider["kind"])}
            >
              <SelectTrigger id="pv-kind" className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {(["openai_compatible", "openai"] as const).map((k) => (
                  <SelectItem key={k} value={k}>
                    {s.kinds[k]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          <div className="flex items-center justify-between gap-4">
            <Label htmlFor="pv-search">{s.hostedSearch}</Label>
            <Switch
              id="pv-search"
              checked={form.supportsHostedWebSearch}
              onCheckedChange={(v) => set("supportsHostedWebSearch", v)}
            />
          </div>
          <details className="group">
            <summary className="text-muted-foreground flex cursor-pointer list-none items-center gap-1 text-sm">
              <ChevronDown className="size-4 transition-transform group-open:rotate-180" />{" "}
              {s.advanced}
            </summary>
            <div className="mt-3 grid grid-cols-2 gap-3">
              <Field id="pv-timeout" label={s.timeout}>
                <Input
                  id="pv-timeout"
                  type="number"
                  min={1}
                  value={form.timeoutS}
                  onChange={(e) => set("timeoutS", e.target.value)}
                />
              </Field>
              <Field id="pv-conc" label={s.concurrency}>
                <Input
                  id="pv-conc"
                  type="number"
                  min={1}
                  placeholder={s.unlimited}
                  value={form.concurrency}
                  onChange={(e) => set("concurrency", e.target.value)}
                />
              </Field>
            </div>
          </details>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              {t.cancel}
            </Button>
            <Button type="submit" disabled={busy}>
              {t.save}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function ModelDialog({
  provider,
  model,
  onClose,
}: {
  provider: Provider;
  model: ModelRow | null;
  onClose: () => void;
}) {
  const actions = useAiActions();
  const [form, setForm] = useState({
    name: model?.name ?? "",
    slug: model?.slug ?? "",
    upstreamId: model?.upstreamId ?? "",
    contextWindow: model?.contextWindow
      ? String(model.contextWindow)
      : "128000",
    reasoningLevels: model?.reasoningLevels ?? ([] as string[]),
    reasoningEffort: model?.reasoningEffort ?? "",
    customLevel: "",
    reasoningSummary: model?.reasoningSummary ?? "__none",
    maxOutputTokens: model?.maxOutputTokens
      ? String(model.maxOutputTokens)
      : "",
    hostedWebSearch:
      model?.hostedWebSearch === true ? "hosted" : model?.hostedWebSearch === false ? "longx" : "provider",
  });
  const set = <K extends keyof typeof form>(k: K, v: (typeof form)[K]) =>
    setForm((f) => ({ ...f, [k]: v }));
  const busy = actions.createModel.isPending || actions.updateModel.isPending;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    const common = {
      name: form.name.trim(),
      upstreamId: form.upstreamId.trim(),
      contextWindow: Number(form.contextWindow) || undefined,
      reasoningLevels: form.reasoningLevels,
      reasoningEffort: form.reasoningEffort.trim() || null,
      reasoningSummary:
        form.reasoningSummary === "__none"
          ? null
          : (form.reasoningSummary as ModelRow["reasoningSummary"]),
      maxOutputTokens: form.maxOutputTokens
        ? Number(form.maxOutputTokens)
        : null,
      hostedWebSearch: form.hostedWebSearch === "hosted" ? true : form.hostedWebSearch === "longx" ? false : null,
      ...(form.slug.trim() ? { slug: form.slug.trim() } : {}),
    };
    const done = {
      onSuccess: () => (toast.success(s.saved), onClose()),
      onError: fail,
    };
    if (model)
      actions.updateModel.mutate({ id: model.id, input: common }, done);
    else
      actions.createModel.mutate(
        { ...common, providerId: provider.id } as ModelInput,
        done,
      );
  };
  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <form onSubmit={submit} className="flex flex-col gap-4">
          <DialogHeader>
            <DialogTitle>
              {model ? s.editModel : s.addModel} · {provider.name}
            </DialogTitle>
          </DialogHeader>
          <Field id="md-name" label={s.name}>
            <Input
              id="md-name"
              value={form.name}
              onChange={(e) => set("name", e.target.value)}
              required
            />
          </Field>
          <Field id="md-upstream" label={s.upstreamId} hint={s.upstreamIdHint}>
            <Input
              id="md-upstream"
              value={form.upstreamId}
              onChange={(e) => set("upstreamId", e.target.value)}
              required
              className="font-mono"
            />
          </Field>
          <Field id="md-slug" label={s.slug} hint={s.slugHint}>
            <Input
              id="md-slug"
              value={form.slug}
              placeholder={form.upstreamId}
              onChange={(e) => set("slug", e.target.value)}
              className="font-mono"
            />
          </Field>
          <Field
            id="md-window"
            label={s.contextWindow}
            hint={s.contextWindowHint}
          >
            <Input
              id="md-window"
              type="number"
              min={1000}
              step={1000}
              value={form.contextWindow}
              onChange={(e) => set("contextWindow", e.target.value)}
              required
            />
          </Field>
          <LevelsEditor
            levels={form.reasoningLevels}
            custom={form.customLevel}
            onCustom={(v) => set("customLevel", v)}
            onChange={(levels) =>
              setForm((f) => ({
                ...f,
                reasoningLevels: levels,
                reasoningEffort:
                  levels.length === 0 || levels.includes(f.reasoningEffort)
                    ? f.reasoningEffort
                    : "",
              }))
            }
          />
          <div className="grid grid-cols-2 gap-3">
            {form.reasoningLevels.length > 0 ? (
              <Field
                id="md-effort"
                label={s.reasoningEffort}
                hint={s.reasoningEffortHint}
              >
                <Select
                  value={form.reasoningEffort || "__none"}
                  onValueChange={(v) =>
                    set("reasoningEffort", v === "__none" ? "" : v)
                  }
                >
                  <SelectTrigger id="md-effort" className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none">—</SelectItem>
                    {form.reasoningLevels.map((level) => (
                      <SelectItem key={level} value={level}>
                        {effortLabel(level)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </Field>
            ) : (
              <Field
                id="md-effort"
                label={s.reasoningEffortFree}
                hint={s.reasoningEffortFreeHint}
              >
                <Input
                  id="md-effort"
                  value={form.reasoningEffort}
                  onChange={(e) => set("reasoningEffort", e.target.value)}
                  className="font-mono"
                />
              </Field>
            )}
            <Field id="md-summary" label={s.reasoningSummary}>
              <Select
                value={form.reasoningSummary}
                onValueChange={(v) => set("reasoningSummary", v)}
              >
                <SelectTrigger id="md-summary" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none">—</SelectItem>
                  {(["auto", "concise", "detailed", "none"] as const).map(
                    (k) => (
                      <SelectItem key={k} value={k}>
                        {s.reasoningSummaries[k]}
                      </SelectItem>
                    ),
                  )}
                </SelectContent>
              </Select>
            </Field>
          </div>
          <Field id="md-max" label={s.maxOutputTokens}>
            <Input
              id="md-max"
              type="number"
              min={1}
              placeholder={s.unlimited}
              value={form.maxOutputTokens}
              onChange={(e) => set("maxOutputTokens", e.target.value)}
            />
          </Field>
          <Field id="md-search" label={s.hostedWebSearch}>
            <Select value={form.hostedWebSearch} onValueChange={(v) => set("hostedWebSearch", v)}>
              <SelectTrigger id="md-search" aria-label={s.hostedWebSearch}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="provider">{s.hostedWebSearchOptions.provider}</SelectItem>
                <SelectItem value="hosted">{s.hostedWebSearchOptions.hosted}</SelectItem>
                <SelectItem value="longx">{s.hostedWebSearchOptions.longx}</SelectItem>
              </SelectContent>
            </Select>
            <p className="text-muted-foreground text-xs">{s.hostedWebSearchHint}</p>
          </Field>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              {t.cancel}
            </Button>
            <Button type="submit" disabled={busy}>
              {t.save}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// codex's known efforts, in order; a model may add its own
const KNOWN_LEVELS = [
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
];

/** The levels a model offers: the known ones as toggles (kept in the known order), any other typed in. */
function LevelsEditor({
  levels,
  custom,
  onCustom,
  onChange,
}: {
  levels: string[];
  custom: string;
  onCustom: (v: string) => void;
  onChange: (levels: string[]) => void;
}) {
  const order = [
    ...KNOWN_LEVELS,
    ...levels.filter((l) => !KNOWN_LEVELS.includes(l)),
  ];
  const toggle = (level: string) =>
    onChange(
      levels.includes(level)
        ? levels.filter((l) => l !== level)
        : order.filter((l) => l === level || levels.includes(l)),
    );
  const addCustom = () => {
    const level = custom.trim();
    if (level && !levels.includes(level)) onChange([...levels, level]);
    onCustom("");
  };
  return (
    <div className="flex flex-col gap-1.5">
      <Label>{s.reasoningLevels}</Label>
      <div className="flex flex-wrap gap-1.5">
        {order.map((level) => (
          <Button
            key={level}
            type="button"
            size="sm"
            variant={levels.includes(level) ? "default" : "outline"}
            className="h-7 font-mono"
            aria-pressed={levels.includes(level)}
            aria-label={level}
            onClick={() => toggle(level)}
          >
            {level}
          </Button>
        ))}
        <div className="flex gap-1">
          <Input
            aria-label={s.customLevel}
            placeholder={s.customLevelPlaceholder}
            value={custom}
            onChange={(e) => onCustom(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                addCustom();
              }
            }}
            className="h-7 w-44 font-mono text-xs"
          />
          <Button type="button" size="sm" variant="outline" className="h-7" onClick={addCustom} disabled={!custom.trim()}>
            {s.addLevel}
          </Button>
        </div>
      </div>
      <p className="text-muted-foreground text-xs">{s.reasoningLevelsHint}</p>
    </div>
  );
}

/**
 * codex's automatic approval review on a model of its own: any model the
 * gateway knows, at one of its levels (or codex's rule: low when offered).
 */
function ReviewModelCard({ models }: { models: ModelRow[] }) {
  const review = useReviewSettings();
  const actions = useAiActions();
  if (!review.data) return null;
  const current = review.data;
  const chosen = models.find((m) => m.slug === current.modelSlug) ?? null;
  const levels = chosen?.reasoningLevels ?? [];
  const save = (input: { modelSlug: string | null; effort: string | null }) =>
    actions.setReviewModel.mutate(input, { onSuccess: () => toast.success(s.saved), onError: fail });
  return (
    <section className="flex flex-col gap-3" data-testid="review-model">
      <h2 className="text-base font-medium">{s.review}</h2>
      <p className="text-muted-foreground text-sm">{s.reviewHint}</p>
      <div className="grid gap-3 rounded-lg border p-3 sm:grid-cols-2">
        <Field id="review-model" label={s.reviewModel}>
          <Select
            value={current.modelSlug ?? "__same"}
            onValueChange={(v) => save({ modelSlug: v === "__same" ? null : v, effort: null })}
          >
            <SelectTrigger id="review-model" className="w-full" aria-label={s.reviewModel}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="__same">{s.reviewSameModel}</SelectItem>
              {models
                .filter((m) => m.slug)
                .map((m) => (
                  <SelectItem key={m.id} value={m.slug!} className="font-mono">
                    {m.slug}
                  </SelectItem>
                ))}
            </SelectContent>
          </Select>
        </Field>
        {chosen && levels.length > 0 ? (
          <Field id="review-effort" label={s.reviewEffort}>
            <Select
              value={current.effort ?? "__auto"}
              onValueChange={(v) => save({ modelSlug: chosen.slug!, effort: v === "__auto" ? null : v })}
            >
              <SelectTrigger id="review-effort" className="w-full" aria-label={s.reviewEffort}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__auto">{s.reviewEffortAuto}</SelectItem>
                {levels.map((level) => (
                  <SelectItem key={level} value={level} className="font-mono">
                    {level}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
        ) : null}
      </div>
    </section>
  );
}

function SearchProviderCard() {
  const search = useSearchProviders();
  const actions = useAiActions();
  const [key, setKey] = useState("");
  const row = search.data?.find((r) => r.default) ?? search.data?.[0];
  if (!row) return null;
  return (
    <section className="flex flex-col gap-3" data-testid="search-provider">
      <h2 className="text-base font-medium">{s.search}</h2>
      <p className="text-muted-foreground text-sm">{s.searchHint}</p>
      <div className="rounded-lg border p-3">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-medium">{row.name}</span>
          {row.hasApiKey ? (
            <Badge variant="secondary">{s.apiKeySet}</Badge>
          ) : (
            <Badge variant="destructive">{s.apiKeyMissing}</Badge>
          )}
        </div>
        <form
          className="mt-3 flex flex-col gap-1.5"
          onSubmit={(e) => {
            e.preventDefault();
            if (!key) return;
            actions.setSearchKey.mutate(
              { id: row.id, apiKey: key },
              {
                onSuccess: () => (toast.success(s.saved), setKey("")),
                onError: fail,
              },
            );
          }}
        >
          <Label htmlFor="sp-key">{s.apiKey}</Label>
          <div className="flex gap-2">
            <Input
              id="sp-key"
              type="password"
              autoComplete="off"
              value={key}
              onChange={(e) => setKey(e.target.value)}
              className="min-w-0 flex-1 font-mono"
            />
            <Button
              type="submit"
              disabled={!key || actions.setSearchKey.isPending}
            >
              {t.save}
            </Button>
          </div>
          {row.hasApiKey ? (
            <p className="text-muted-foreground text-xs">{s.keepKey}</p>
          ) : null}
        </form>
      </div>
    </section>
  );
}

function Field({
  id,
  label,
  hint,
  className = "",
  children,
}: {
  id: string;
  label: string;
  hint?: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={`flex flex-col gap-1.5 ${className}`}>
      <Label htmlFor={id}>{label}</Label>
      {children}
      {hint ? <p className="text-muted-foreground text-xs">{hint}</p> : null}
    </div>
  );
}
