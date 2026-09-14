// Settings → 模型与 Provider: every provider as a card — its endpoint, key
// status and last error, then its models with the default marked — and the
// search provider's key. Adding and editing happen in dialogs; deleting
// asks first.
import { CheckCircle2, MoreHorizontal, Plus, Star } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";
import { relativeTime } from "@/core/format";
import { useAiActions, useModelRows, useProviders, useSearchProviders, type ModelInput, type ModelRow, type Provider, type ProviderInput } from "@/core/ai";
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
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/ui/components/ui/dropdown-menu";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

const s = t.ai;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function ModelsSection() {
  const providers = useProviders();
  const models = useModelRows();
  const [editing, setEditing] = useState<Provider | "new" | null>(null);
  if (providers.isPending || models.isPending) return <Skeleton className="h-24 w-full" data-testid="section-models" />;
  if (providers.isError) return <p className="text-destructive text-sm">{providers.error.message}</p>;
  if (models.isError) return <p className="text-destructive text-sm">{models.error.message}</p>;
  return (
    <div className="flex flex-col gap-8" data-testid="section-models">
      <section className="flex flex-col gap-3">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-base font-medium">{s.providers}</h2>
          <Button size="sm" onClick={() => setEditing("new")}>
            <Plus className="size-4" /> {s.addProvider}
          </Button>
        </div>
        <p className="text-muted-foreground text-sm">{s.providersHint}</p>
        {providers.data.map((p) => (
          <ProviderCard key={p.id} provider={p} models={models.data.filter((m) => m.providerId === p.id)} onEdit={() => setEditing(p)} />
        ))}
      </section>
      <SearchProviderCard />
      {editing ? <ProviderDialog provider={editing === "new" ? null : editing} onClose={() => setEditing(null)} /> : null}
    </div>
  );
}

function ProviderCard({ provider, models, onEdit }: { provider: Provider; models: ModelRow[]; onEdit: () => void }) {
  const actions = useAiActions();
  const [adding, setAdding] = useState<ModelRow | "new" | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
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
          <p className="text-muted-foreground mt-1 truncate font-mono text-xs">{provider.baseUrl}</p>
          {provider.lastError ? (
            <p className="text-destructive mt-1 text-xs">
              {s.lastError}: {provider.lastError}
            </p>
          ) : provider.lastCheckedAt ? (
            <p className="text-muted-foreground mt-1 text-xs">{s.lastChecked(relativeTime(provider.lastCheckedAt))}</p>
          ) : null}
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="size-8 shrink-0" aria-label={`${provider.name} 的操作`}>
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onSelect={onEdit}>{s.editProvider}</DropdownMenuItem>
            <DropdownMenuItem onSelect={() => setAdding("new")}>{s.addModel}</DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onSelect={() => setConfirmDelete(true)}>
              {s.deleteProvider}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <ul className="divide-y border-t">
        {models.length === 0 ? <li className="text-muted-foreground px-3 py-2 text-sm">{s.noModels}</li> : null}
        {models.map((m) => (
          <ModelRowView key={m.id} model={m} onEdit={() => setAdding(m)} />
        ))}
        <li className="px-3 py-2">
          <Button variant="ghost" size="sm" onClick={() => setAdding("new")}>
            <Plus className="size-4" /> {s.addModel}
          </Button>
        </li>
      </ul>
      {adding ? <ModelDialog provider={provider} model={adding === "new" ? null : adding} onClose={() => setAdding(null)} /> : null}
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.deleteProviderTitle(provider.name)}</AlertDialogTitle>
            <AlertDialogDescription>{s.deleteProviderHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => actions.deleteProvider.mutate(provider.id, { onSuccess: () => toast.success(s.deleted), onError: fail })}>
              {t.delete}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function ModelRowView({ model, onEdit }: { model: ModelRow; onEdit: () => void }) {
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
  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-sm" data-testid={`model-${model.id}`}>
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-2">
          <span className="font-mono text-xs">{model.slug ?? model.upstreamId}</span>
          {model.default ? (
            <Badge>
              <Star className="size-3" /> {s.default}
            </Badge>
          ) : null}
        </span>
        <span className="text-muted-foreground text-xs">
          {model.name} · {model.upstreamId}
          {model.contextWindow ? ` · ${Math.round(model.contextWindow / 1000)}k` : ""}
          {model.reasoningEffort ? ` · ${model.reasoningEffort}` : ""}
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
      <div className="flex items-center gap-1">
        <Button variant="outline" size="sm" className="h-7" onClick={check} disabled={actions.checkModel.isPending}>
          {s.check}
        </Button>
        {!model.default ? (
          <Button variant="outline" size="sm" className="h-7" onClick={() => actions.makeDefault.mutate(model.id, { onError: fail })}>
            {s.makeDefault}
          </Button>
        ) : null}
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="size-7" aria-label={`${model.name} 的操作`}>
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onSelect={onEdit}>{s.editModel}</DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onSelect={() => setConfirmDelete(true)}>
              {s.deleteModel}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.deleteModelTitle(model.name)}</AlertDialogTitle>
            <AlertDialogDescription>{s.deleteModelHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => actions.deleteModel.mutate(model.id, { onSuccess: () => toast.success(s.deleted), onError: fail })}>
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

function ProviderDialog({ provider, onClose }: { provider: Provider | null; onClose: () => void }) {
  const actions = useAiActions();
  const [form, setForm] = useState({
    name: provider?.name ?? "",
    slug: provider?.slug ?? "",
    baseUrl: provider?.baseUrl ?? "",
    apiKey: "",
    kind: provider?.kind ?? "openai_compatible",
    supportsHostedWebSearch: provider?.supportsHostedWebSearch ?? false,
    timeoutS: String(Math.round((provider?.requestTimeoutMs ?? 600_000) / 1000)),
    concurrency: provider?.maxConcurrentRequests ? String(provider.maxConcurrentRequests) : "",
  });
  const set = <K extends keyof typeof form>(k: K, v: (typeof form)[K]) => setForm((f) => ({ ...f, [k]: v }));
  const busy = actions.createProvider.isPending || actions.updateProvider.isPending;
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
    const done = { onSuccess: () => (toast.success(s.saved), onClose()), onError: fail };
    if (provider) actions.updateProvider.mutate({ id: provider.id, input: common }, done);
    else actions.createProvider.mutate({ ...common, slug: form.slug.trim() || slugOf(form.name) } as ProviderInput, done);
  };
  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <form onSubmit={submit} className="flex flex-col gap-4">
          <DialogHeader>
            <DialogTitle>{provider ? s.editProvider : s.addProvider}</DialogTitle>
          </DialogHeader>
          <Field id="pv-name" label={s.name}>
            <Input id="pv-name" value={form.name} onChange={(e) => set("name", e.target.value)} required />
          </Field>
          {!provider ? (
            <Field id="pv-slug" label={s.slug} hint={s.slugHint}>
              <Input id="pv-slug" value={form.slug} placeholder={slugOf(form.name)} onChange={(e) => set("slug", e.target.value)} className="font-mono" />
            </Field>
          ) : null}
          <Field id="pv-url" label={s.baseUrl}>
            <Input id="pv-url" type="url" value={form.baseUrl} placeholder="https://api.deepseek.com/v1" onChange={(e) => set("baseUrl", e.target.value)} required className="font-mono" />
          </Field>
          <Field id="pv-key" label={s.apiKey} hint={provider?.hasApiKey ? s.keepKey : undefined}>
            <Input id="pv-key" type="password" autoComplete="off" value={form.apiKey} onChange={(e) => set("apiKey", e.target.value)} className="font-mono" />
          </Field>
          <Field id="pv-kind" label={s.kind} hint={s.kindHint}>
            <Select value={form.kind} onValueChange={(v) => set("kind", v as Provider["kind"])}>
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
            <Switch id="pv-search" checked={form.supportsHostedWebSearch} onCheckedChange={(v) => set("supportsHostedWebSearch", v)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Field id="pv-timeout" label={s.timeout}>
              <Input id="pv-timeout" type="number" min={1} value={form.timeoutS} onChange={(e) => set("timeoutS", e.target.value)} />
            </Field>
            <Field id="pv-conc" label={s.concurrency}>
              <Input id="pv-conc" type="number" min={1} placeholder={s.unlimited} value={form.concurrency} onChange={(e) => set("concurrency", e.target.value)} />
            </Field>
          </div>
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

function ModelDialog({ provider, model, onClose }: { provider: Provider; model: ModelRow | null; onClose: () => void }) {
  const actions = useAiActions();
  const [form, setForm] = useState({
    name: model?.name ?? "",
    slug: model?.slug ?? "",
    upstreamId: model?.upstreamId ?? "",
    contextWindow: model?.contextWindow ? String(model.contextWindow) : "128000",
    reasoningEffort: model?.reasoningEffort ?? "",
    reasoningSummary: model?.reasoningSummary ?? "__none",
    maxOutputTokens: model?.maxOutputTokens ? String(model.maxOutputTokens) : "",
  });
  const set = <K extends keyof typeof form>(k: K, v: (typeof form)[K]) => setForm((f) => ({ ...f, [k]: v }));
  const busy = actions.createModel.isPending || actions.updateModel.isPending;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    const common = {
      name: form.name.trim(),
      upstreamId: form.upstreamId.trim(),
      contextWindow: Number(form.contextWindow) || undefined,
      reasoningEffort: form.reasoningEffort.trim() || null,
      reasoningSummary: form.reasoningSummary === "__none" ? null : (form.reasoningSummary as ModelRow["reasoningSummary"]),
      maxOutputTokens: form.maxOutputTokens ? Number(form.maxOutputTokens) : null,
      ...(form.slug.trim() ? { slug: form.slug.trim() } : {}),
    };
    const done = { onSuccess: () => (toast.success(s.saved), onClose()), onError: fail };
    if (model) actions.updateModel.mutate({ id: model.id, input: common }, done);
    else actions.createModel.mutate({ ...common, providerId: provider.id } as ModelInput, done);
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
            <Input id="md-name" value={form.name} onChange={(e) => set("name", e.target.value)} required />
          </Field>
          <Field id="md-upstream" label={s.upstreamId} hint={s.upstreamIdHint}>
            <Input id="md-upstream" value={form.upstreamId} onChange={(e) => set("upstreamId", e.target.value)} required className="font-mono" />
          </Field>
          <Field id="md-slug" label={s.slug} hint={s.slugHint}>
            <Input id="md-slug" value={form.slug} placeholder={form.upstreamId} onChange={(e) => set("slug", e.target.value)} className="font-mono" />
          </Field>
          <Field id="md-window" label={s.contextWindow} hint={s.contextWindowHint}>
            <Input id="md-window" type="number" min={1000} step={1000} value={form.contextWindow} onChange={(e) => set("contextWindow", e.target.value)} required />
          </Field>
          <div className="grid grid-cols-2 gap-3">
            <Field id="md-effort" label={s.reasoningEffort} hint={s.reasoningEffortHint}>
              <Input id="md-effort" value={form.reasoningEffort} onChange={(e) => set("reasoningEffort", e.target.value)} className="font-mono" />
            </Field>
            <Field id="md-summary" label={s.reasoningSummary}>
              <Select value={form.reasoningSummary} onValueChange={(v) => set("reasoningSummary", v)}>
                <SelectTrigger id="md-summary" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none">—</SelectItem>
                  {(["auto", "concise", "detailed", "none"] as const).map((k) => (
                    <SelectItem key={k} value={k}>
                      {s.reasoningSummaries[k]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          </div>
          <Field id="md-max" label={s.maxOutputTokens}>
            <Input id="md-max" type="number" min={1} placeholder={s.unlimited} value={form.maxOutputTokens} onChange={(e) => set("maxOutputTokens", e.target.value)} />
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
          {row.hasApiKey ? <Badge variant="secondary">{s.apiKeySet}</Badge> : <Badge variant="destructive">{s.apiKeyMissing}</Badge>}
        </div>
        <form
          className="mt-3 flex flex-col gap-1.5"
          onSubmit={(e) => {
            e.preventDefault();
            if (!key) return;
            actions.setSearchKey.mutate({ id: row.id, apiKey: key }, { onSuccess: () => (toast.success(s.saved), setKey("")), onError: fail });
          }}
        >
          <Label htmlFor="sp-key">{s.apiKey}</Label>
          <div className="flex gap-2">
            <Input id="sp-key" type="password" autoComplete="off" value={key} onChange={(e) => setKey(e.target.value)} className="min-w-0 flex-1 font-mono" />
            <Button type="submit" disabled={!key || actions.setSearchKey.isPending}>
              {t.save}
            </Button>
          </div>
          {row.hasApiKey ? <p className="text-muted-foreground text-xs">{s.keepKey}</p> : null}
        </form>
      </div>
    </section>
  );
}

function Field({ id, label, hint, className = "", children }: { id: string; label: string; hint?: string; className?: string; children: React.ReactNode }) {
  return (
    <div className={`flex flex-col gap-1.5 ${className}`}>
      <Label htmlFor={id}>{label}</Label>
      {children}
      {hint ? <p className="text-muted-foreground text-xs">{hint}</p> : null}
    </div>
  );
}
