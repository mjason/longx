import { useTranslation } from "react-i18next";
// Settings → Provider: where the models come from — every provider as a
// card folded to one line (kind, key or login, how many models, which tiers
// use them, the last check or error), unfolded to its models (window,
// levels, default level, whether it searches on its side, the fallback
// model marked 兜底). What a person sets day to day — the default model,
// the tiers, web search — is Settings → 模型 (./ModelsSection). Adding and
// editing happen in dialogs; deleting asks first.
import {
  CheckCircle2,
  ChevronDown,
  ExternalLink,
  MoreHorizontal,
  Plus,
  Trash2,
} from "lucide-react";
import { ChatGptLoginDialog } from "./ChatGptLoginDialog";
import { useCredentials } from "@/core/credentials";
import { useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";
import { relativeTime } from "@/core/format";
import {
  useAiActions,
  useDiscoverModels,
  useModelRows,
  usePresets,
  useProviders,
  useModelAliases,
  type ModelAlias,
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
  DialogBody,
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
  SelectGroup,
  SelectItem,
  SelectLabel,
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
  | { kind: "login"; credentialId: string }
  | { kind: "custom"; provider: Provider | null }
  | null;

export function ProvidersSection() {
  const providers = useProviders();
  const models = useModelRows();
  const presets = usePresets();
  const aliases = useModelAliases();
  const [editing, setEditing] = useState<Editing>(null);
  if (providers.isPending || models.isPending)
    return <Skeleton className="h-24 w-full" data-testid="section-providers" />;
  if (providers.isError)
    return (
      <p className="text-destructive text-sm">{providers.error.message}</p>
    );
  if (models.isError)
    return <p className="text-destructive text-sm">{models.error.message}</p>;
  const fallback = models.data.find((m) => m.default) ?? null;
  return (
    <div className="flex flex-col gap-8" data-testid="section-providers">
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
            onLogin={(credentialId) => setEditing({ kind: "login", credentialId })}
            usedBy={usedBy(aliases.data ?? [], models.data.filter((m) => m.providerId === p.id))}
          />
        ))}
        {fallback ? (
          <p className="text-muted-foreground text-xs" data-testid="fallback-hint">
            <Badge variant="outline" className="border-warning/50 text-warning mr-2">{s.fallbackModel}</Badge>
            {s.fallbackHint(fallback.slug ?? fallback.upstreamId)}
          </p>
        ) : null}
      </section>
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
      {editing?.kind === "login" ? (
        <ChatGptLoginDialog credentialId={editing.credentialId} onClose={() => setEditing(null)} />
      ) : null}
      {editing?.kind === "preset" ? (
        <PresetDialog
          preset={editing.preset}
          onLogin={(credentialId) => setEditing({ kind: "login", credentialId })}
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
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{s.chooseTemplate}</DialogTitle>
          <DialogDescription>{s.chooseTemplateHint}</DialogDescription>
        </DialogHeader>
        <DialogBody className="flex flex-col gap-4">
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
                <span
                  className="text-muted-foreground w-full truncate font-mono text-xs"
                  title={preset.baseUrl}
                >
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
        </DialogBody>
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
  onLogin,
}: {
  preset: Preset;
  onClose: () => void;
  /** a subscription template: the credential is made, the login comes next */
  onLogin: (credentialId: string) => void;
}) {
    useTranslation();
  const actions = useAiActions();
  const providers = useProviders();
  // an installed provider without a key still wants one — unless its key is a login
  const needsKey =
    !preset.credential &&
    (!preset.installed ||
      !providers.data?.find((p) => p.id === preset.providerId)?.hasApiKey);
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
      {
        onSuccess: (r) => {
          toast.success(s.saved);
          // a subscription: straight on to the login
          if (preset.credential && r.credentialId) onLogin(r.credentialId);
          else onClose();
        },
        onError: fail,
      },
    );
  };
  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent>
        <form onSubmit={submit} className="flex min-h-0 flex-1 flex-col gap-4">
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
          <DialogBody className="flex flex-col gap-4">
            {preset.credential ? (
              <p className="text-muted-foreground text-sm">{s.presetLoginHint}</p>
            ) : null}
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
              {preset.credential ? null : (
                <a
                  href={preset.keyUrl}
                  target="_blank"
                  rel="noreferrer"
                  className="text-primary inline-flex items-center gap-1 underline-offset-4 hover:underline"
                >
                  {s.getKey} <ExternalLink className="size-3" />
                </a>
              )}
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
          </DialogBody>
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

/** The tiers and aliases whose chain uses one of these models ("ultra / pro"). */
function usedBy(aliases: ModelAlias[], models: ModelRow[]): string[] {
  const slugs = new Set(models.map((m) => m.slug).filter(Boolean));
  return aliases.filter((a) => a.models.some((m) => slugs.has(m))).map((a) => a.name);
}

/** Whether a model searches the web on its provider's side (its own say, else the provider's). */
export function searchesItself(model: ModelRow, provider: Pick<Provider, "supportsHostedWebSearch"> | undefined): boolean {
  return model.hostedWebSearch ?? provider?.supportsHostedWebSearch ?? false;
}

function ProviderCard({
  provider,
  models,
  preset,
  usedBy,
  onEdit,
  onAddFromPreset,
  onLogin,
}: {
  provider: Provider;
  models: ModelRow[];
  preset: Preset | null;
  usedBy: string[];
  onEdit: () => void;
  onAddFromPreset: (preset: Preset) => void;
  onLogin: (credentialId: string) => void;
}) {
    useTranslation();
  const actions = useAiActions();
  // a provider on a credential (a ChatGPT subscription): its login is its key
  const credentials = useCredentials({ refetchInterval: provider.credentialId ? 5000 : false });
  const credential = provider.credentialId ? (credentials.data?.find((c) => c.id === provider.credentialId) ?? null) : null;
  // a login not read yet is no problem yet
  const keyOk = provider.credentialId ? credentials.isPending || credential?.status === "ready" : provider.hasApiKey;
  // folded to one line; one that needs looking at (no key, an error, no model) opens by itself
  const attention = !keyOk || provider.lastError !== null || models.length === 0;
  const [open, setOpen] = useState(attention);
  useEffect(() => {
    if (attention) setOpen(true);
  }, [attention]);
  const [adding, setAdding] = useState<ModelRow | "new" | null>(null);
  const [discovering, setDiscovering] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  // the template this provider came from still has models to offer
  const missing = preset?.models.some((m) => !m.installed) ? preset : null;
  return (
    <div className="rounded-lg border" data-testid={`provider-${provider.id}`}>
      <div className="flex items-center gap-2 p-3">
        <button
          type="button"
          aria-expanded={open}
          aria-label={provider.name}
          onClick={() => setOpen(!open)}
          className="flex min-w-0 flex-1 flex-wrap items-center gap-2 text-left"
        >
          <ChevronDown className={`text-muted-foreground size-4 shrink-0 transition-transform ${open ? "" : "-rotate-90"}`} />
          <span className="font-medium">{provider.name}</span>
          <Badge variant="outline">{s.kinds[provider.kind]}</Badge>
          {provider.credentialId ? (
            credential?.status === "ready" ? (
              <Badge variant="secondary">{s.loginSet}</Badge>
            ) : credential?.status === "expired" || credential?.status === "error" ? (
              <Badge variant="destructive">{s.loginExpired}</Badge>
            ) : (
              <Badge variant="destructive">{s.loginMissing}</Badge>
            )
          ) : provider.hasApiKey ? (
            <Badge variant="secondary">{s.apiKeySet}</Badge>
          ) : (
            <Badge variant="destructive">{s.apiKeyMissing}</Badge>
          )}
          {provider.supportsHostedWebSearch ? <SearchBadge own /> : null}
          <span className="text-muted-foreground ml-auto text-xs">
            {[s.providerModels(models.length), usedBy.length ? s.usedBy(usedBy.join(" / ")) : null, !provider.lastError && provider.lastCheckedAt ? s.lastChecked(relativeTime(provider.lastCheckedAt)) : null]
              .filter(Boolean)
              .join(" · ")}
          </span>
        </button>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="size-8 shrink-0" aria-label={t.actionsFor(provider.name)}>
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            {provider.credentialId ? (
              <DropdownMenuItem onSelect={() => onLogin(provider.credentialId!)}>{s.loginChatGpt}</DropdownMenuItem>
            ) : null}
            <DropdownMenuItem onSelect={onEdit}>{s.editProvider}</DropdownMenuItem>
            <DropdownMenuItem onSelect={() => setAdding("new")}>{s.addModel}</DropdownMenuItem>
            <DropdownMenuItem onSelect={() => setDiscovering(true)}>{s.discover}</DropdownMenuItem>
            {missing ? <DropdownMenuItem onSelect={() => onAddFromPreset(missing)}>{s.addFromPreset}</DropdownMenuItem> : null}
            <DropdownMenuItem variant="destructive" onSelect={() => setConfirmDelete(true)}>
              {s.deleteProvider}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      {provider.lastError ? (
        <p className="text-destructive -mt-1 px-3 pb-2 pl-9 text-xs">
          {s.lastError}: {provider.lastError}
        </p>
      ) : null}
      {open ? (
        <>
          <p className="text-muted-foreground truncate border-t px-3 py-1.5 pl-9 font-mono text-xs">{provider.baseUrl}</p>
          <ul className="divide-y border-t">
            {models.length === 0 ? <li className="text-muted-foreground px-3 py-2 pl-9 text-sm">{s.noModels}</li> : null}
            {models.map((m) => (
              <ModelRowView key={m.id} model={m} searches={searchesItself(m, provider)} onEdit={() => setAdding(m)} />
            ))}
            <li className="px-3 py-1.5 pl-7">
              <Button variant="ghost" size="sm" onClick={() => setAdding("new")}>
                <Plus className="size-4" /> {s.addModel}
              </Button>
            </li>
          </ul>
        </>
      ) : null}
      {adding ? <ModelDialog provider={provider} model={adding === "new" ? null : adding} onClose={() => setAdding(null)} /> : null}
      {discovering ? <DiscoverDialog provider={provider} onClose={() => setDiscovering(false)} /> : null}
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.deleteProviderTitle(provider.name)}</AlertDialogTitle>
            <AlertDialogDescription>{s.deleteProviderHint}</AlertDialogDescription>
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

/** 自带搜索 (the provider searches) or 代搜 (Longx's web_search). */
export function SearchBadge({ own }: { own: boolean }) {
  return (
    <Badge variant="outline" className={own ? "border-success/40 text-success" : "border-primary/40 text-primary"}>
      {own ? s.searchOwn : s.searchOurs}
    </Badge>
  );
}

function ModelRowView({ model, searches, onEdit }: { model: ModelRow; searches: boolean; onEdit: () => void }) {
    useTranslation();
  const actions = useAiActions();
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [checked, setChecked] = useState<{ ok: boolean; latencyMs: number | null; error: string | null } | null>(null);
  const check = () =>
    actions.checkModel.mutate(model.id, {
      onSuccess: (r) => {
        setChecked(r);
        if (r.ok) toast.success(s.checkOk(r.latencyMs ?? 0));
        else toast.error(s.checkFailed(r.error ?? ""));
      },
      onError: fail,
    });
  const slug = model.slug ?? model.upstreamId;
  const meta = [
    model.name !== slug ? model.name : null,
    model.upstreamId !== slug ? model.upstreamId : null,
    model.contextWindow ? formatWindow(model.contextWindow) : null,
    model.reasoningLevels.length > 0 ? s.levelsCount(model.reasoningLevels.length) : null,
    model.reasoningEffort ? `${s.default} ${effortLabel(model.reasoningEffort)}` : null,
  ].filter(Boolean);
  return (
    <li className="flex items-center gap-3 px-3 py-2 pl-9 text-sm" data-testid={`model-${model.id}`}>
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="flex flex-wrap items-center gap-2">
          <span className="font-mono text-xs">{slug}</span>
          {model.default ? (
            <Badge variant="outline" className="border-warning/50 text-warning" title={s.fallbackHint(slug)}>
              {s.fallbackModel}
            </Badge>
          ) : null}
          <SearchBadge own={searches} />
        </span>
        <span className="text-muted-foreground text-xs" title={model.reasoningLevels.map(effortLabel).join(" / ")}>
          {meta.join(" · ")}
        </span>
        {checked ? (
          <span className={`text-xs ${checked.ok ? "text-success" : "text-destructive"}`}>
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
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon" className="size-7" aria-label={t.actionsFor(model.name)}>
            <MoreHorizontal className="size-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem onSelect={check} disabled={actions.checkModel.isPending}>
            {s.check}
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={onEdit}>{s.editModel}</DropdownMenuItem>
          {!model.default ? (
            <DropdownMenuItem onSelect={() => actions.makeDefault.mutate(model.id, { onError: fail })}>{s.makeDefault}</DropdownMenuItem>
          ) : null}
          <DropdownMenuItem variant="destructive" onSelect={() => setConfirmDelete(true)}>
            {s.deleteModel}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.deleteModelTitle(model.name)}</AlertDialogTitle>
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
    useTranslation();
  const actions = useAiActions();
  const [form, setForm] = useState({
    name: provider?.name ?? "",
    slug: provider?.slug ?? "",
    baseUrl: provider?.baseUrl ?? "",
    apiKey: "",
    kind: provider?.kind ?? "openai_compatible",
    supportsHostedWebSearch: provider?.supportsHostedWebSearch ?? false,
    // "auto" follows the kind (OpenAI sends it, a compatible service does not)
    promptCacheKey: provider?.promptCacheKey === true ? "on" : provider?.promptCacheKey === false ? "off" : "auto",
    timeoutS: String(
      Math.round((provider?.requestTimeoutMs ?? 600_000) / 1000),
    ),
    idleS: String(Math.round((provider?.streamIdleTimeoutMs ?? 300_000) / 1000)),
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
      promptCacheKey: form.promptCacheKey === "on" ? true : form.promptCacheKey === "off" ? false : null,
      requestTimeoutMs: Math.max(1, Number(form.timeoutS) || 600) * 1000,
      streamIdleTimeoutMs: Math.max(1, Number(form.idleS) || 300) * 1000,
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
      <DialogContent>
        <form onSubmit={submit} className="flex min-h-0 flex-1 flex-col gap-4">
          <DialogHeader>
            <DialogTitle>
              {provider ? s.editProvider : s.addProvider}
            </DialogTitle>
          </DialogHeader>
          <DialogBody className="flex flex-col gap-4">
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
            <Field id="pv-cache" label="prompt_cache_key" hint={s.promptCacheKeyHint}>
              <Select value={form.promptCacheKey} onValueChange={(v) => set("promptCacheKey", v)}>
                <SelectTrigger id="pv-cache" aria-label="prompt_cache_key">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="auto">{s.promptCacheKeyOptions.auto}</SelectItem>
                  <SelectItem value="on">{s.promptCacheKeyOptions.on}</SelectItem>
                  <SelectItem value="off">{s.promptCacheKeyOptions.off}</SelectItem>
                </SelectContent>
              </Select>
            </Field>
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
                <Field id="pv-idle" label={s.idleTimeout} hint={s.idleTimeoutHint}>
                  <Input
                    id="pv-idle"
                    type="number"
                    min={1}
                    value={form.idleS}
                    onChange={(e) => set("idleS", e.target.value)}
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
          </DialogBody>
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
    useTranslation();
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
    verbosity: model?.verbosity ?? "__none",
    maxOutputTokens: model?.maxOutputTokens
      ? String(model.maxOutputTokens)
      : "",
    hostedWebSearch:
      model?.hostedWebSearch === true
        ? "hosted"
        : model?.hostedWebSearch === false
          ? "longx"
          : "provider",
    imageGeneration: model?.imageGeneration === true,
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
      verbosity: form.verbosity === "__none" ? null : (form.verbosity as ModelRow["verbosity"]),
      maxOutputTokens: form.maxOutputTokens
        ? Number(form.maxOutputTokens)
        : null,
      hostedWebSearch:
        form.hostedWebSearch === "hosted"
          ? true
          : form.hostedWebSearch === "longx"
            ? false
            : null,
      imageGeneration: form.imageGeneration,
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
      <DialogContent>
        <form onSubmit={submit} className="flex min-h-0 flex-1 flex-col gap-4">
          <DialogHeader>
            <DialogTitle>
              {model ? s.editModel : s.addModel} · {provider.name}
            </DialogTitle>
          </DialogHeader>
          <DialogBody className="flex flex-col gap-4">
            <Field id="md-name" label={s.name}>
              <Input
                id="md-name"
                value={form.name}
                onChange={(e) => set("name", e.target.value)}
                required
              />
            </Field>
            <Field
              id="md-upstream"
              label={s.upstreamId}
              hint={s.upstreamIdHint}
            >
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
                step={1}
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
              <Field id="md-summary" label={s.reasoningSummary} hint={s.reasoningSummaryHint}>
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
            <Field id="md-verbosity" label={s.verbosity} hint={s.verbosityHint}>
              <Select value={form.verbosity} onValueChange={(v) => set("verbosity", v)}>
                <SelectTrigger id="md-verbosity" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none">—</SelectItem>
                  {(["low", "medium", "high"] as const).map((k) => (
                    <SelectItem key={k} value={k}>
                      {s.verbosities[k]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
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
              <Select
                value={form.hostedWebSearch}
                onValueChange={(v) => set("hostedWebSearch", v)}
              >
                <SelectTrigger id="md-search" aria-label={s.hostedWebSearch}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="provider">
                    {s.hostedWebSearchOptions.provider}
                  </SelectItem>
                  <SelectItem value="hosted">
                    {s.hostedWebSearchOptions.hosted}
                  </SelectItem>
                  <SelectItem value="longx">
                    {s.hostedWebSearchOptions.longx}
                  </SelectItem>
                </SelectContent>
              </Select>
              <p className="text-muted-foreground text-xs">
                {s.hostedWebSearchHint}
              </p>
            </Field>
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center gap-3">
                <Switch id="md-image" checked={form.imageGeneration} onCheckedChange={(v) => set("imageGeneration", v)} aria-label={s.imageGeneration} />
                <Label htmlFor="md-image">{s.imageGeneration}</Label>
              </div>
              <p className="text-muted-foreground text-xs">{s.imageGenerationHint}</p>
            </div>
          </DialogBody>
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

// the known efforts, in order; a model may add its own
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
          <Button
            type="button"
            size="sm"
            variant="outline"
            className="h-7"
            onClick={addCustom}
            disabled={!custom.trim()}
          >
            {s.addLevel}
          </Button>
        </div>
      </div>
      <p className="text-muted-foreground text-xs">{s.reasoningLevelsHint}</p>
    </div>
  );
}

/**
 * Tiers (flagship / advanced / standard) and the team's own aliases, each a
 * chain of models: what a description names instead of a concrete slug, so
 * a migration is a change here and nowhere else.
 */
/** What runs when nobody picks: a tier by preference, an alias or a model. */
/**
 * The provider's own model list (OpenAI's GET /models standard; OpenRouter's
 * entries carry window, levels and modalities, a plain gateway's only ids)
 * as a checklist — the registry's model-picker, like the preset dialog —
 * with a filter for long lists; picked ones become rows.
 */
function DiscoverDialog({
  provider,
  onClose,
}: {
  provider: Provider;
  onClose: () => void;
}) {
    useTranslation();
  const discovery = useDiscoverModels(provider.id);
  const actions = useAiActions();
  const [filter, setFilter] = useState("");
  const [chosen, setChosen] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const candidates = (discovery.data?.ok ? discovery.data.models : []).filter(
    (m) => !m.installed,
  );
  const q = filter.trim().toLowerCase();
  const shown = q
    ? candidates.filter(
        (m) =>
          m.id.toLowerCase().includes(q) ||
          m.name.toLowerCase().includes(q) ||
          (m.ownedBy ?? "").toLowerCase().includes(q),
      )
    : candidates;
  const rows: PickableModel[] = shown.map((m) => ({
    id: m.id,
    name: m.name,
    family: m.ownedBy ?? provider.name,
    context: m.contextWindow ? formatWindow(m.contextWindow) : "",
    ...(m.name !== m.id ? { note: m.id } : {}),
    capabilities: [
      ...(m.imageInput ? [s.image] : []),
      ...(m.reasoningLevels.length > 0
        ? [m.reasoningLevels.map(effortLabel).join(" / ")]
        : []),
    ],
  }));
  const toggle = (id: string) =>
    setChosen((ids) =>
      ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id],
    );
  const add = async () => {
    setBusy(true);
    try {
      for (const id of chosen) {
        const m = candidates.find((c) => c.id === id);
        if (!m) continue;
        await actions.createModel.mutateAsync({
          providerId: provider.id,
          upstreamId: m.id,
          name: m.name,
          ...(m.contextWindow ? { contextWindow: m.contextWindow } : {}),
          ...(m.reasoningLevels.length > 0
            ? { reasoningLevels: m.reasoningLevels }
            : {}),
          ...(m.reasoningEffort ? { reasoningEffort: m.reasoningEffort } : {}),
        });
      }
      toast.success(s.discoverAdded(chosen.length));
      onClose();
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open onOpenChange={(open) => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{s.discoverTitle(provider.name)}</DialogTitle>
          <DialogDescription>{s.discoverHint}</DialogDescription>
        </DialogHeader>
        <DialogBody className="flex flex-col gap-4">
          {discovery.isPending ? (
            <p className="text-muted-foreground text-sm">{s.discoverLoading}</p>
          ) : discovery.isError ? (
            <p className="text-destructive text-sm">
              {discovery.error.message}
            </p>
          ) : !discovery.data.ok ? (
            <p className="text-destructive text-sm">{discovery.data.error}</p>
          ) : candidates.length === 0 ? (
            <p className="text-muted-foreground text-sm">{s.discoverEmpty}</p>
          ) : (
            <div className="flex flex-col gap-3">
              <Input
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder={s.discoverFilter}
                aria-label={s.discoverFilter}
              />
              <ModelPicker
                models={rows}
                selectedIds={chosen}
                onToggle={toggle}
                className="max-w-none"
              />
            </div>
          )}
        </DialogBody>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            {t.cancel}
          </Button>
          <Button
            type="button"
            onClick={add}
            disabled={chosen.length === 0 || busy}
          >
            {s.discoverAdd(chosen.length)}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
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
