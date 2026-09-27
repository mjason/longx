// Settings → HTTPS: Longx served over https with a certificate Let's Encrypt
// signs through the DNS-01 challenge (Longx.Tls) — the state (off, being
// obtained, served at an address until a date, failed), the names with the
// A record to add and what each resolves to now, the DNS provider picked from
// lego's list with its keys (sent once, stored encrypted, never shown again:
// a stored one is an empty field saying so), the CA / email / port / redirect
// under 更多选项, and 保存并申请证书 / 立即续期 / 关闭 HTTPS.
import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { Check, ChevronsUpDown, ExternalLink, Loader2, X } from "lucide-react";
import {
  FEATURED_PROVIDERS,
  daysLeft,
  envInput,
  parseDomains,
  providerLabel,
  tlsBusy,
  useDisableTls,
  useIssueTls,
  useSaveTls,
  useTlsProviders,
  useTlsStatus,
  type TlsProvider,
  type TlsStatus,
} from "@/core/https";
import { DownloadBar } from "@/ui/components/DownloadBar";
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
import { Button } from "@/ui/components/ui/button";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/ui/components/ui/collapsible";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/ui/components/ui/command";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

const s = t.https;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function HttpsSection() {
  const status = useTlsStatus();
  const providers = useTlsProviders();
  return (
    <div className="flex max-w-2xl flex-col gap-6" data-testid="section-https">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      {status.data && providers.data ? (
        <>
          <StateCard status={status.data} />
          <SettingsForm status={status.data} providers={providers.data} />
        </>
      ) : (
        <Skeleton className="h-40" />
      )}
    </div>
  );
}

function StateCard({ status }: { status: TlsStatus }) {
  const issue = useIssueTls();
  const disable = useDisableTls();
  const [confirming, setConfirming] = useState(false);
  const busy = tlsBusy(status.stage);
  const days = daysLeft(status.certificate?.notAfter);
  const percent = status.total ? Math.floor((status.received / status.total) * 100) : null;

  return (
    <div className="rounded-lg border p-3" data-testid="tls-state">
      {busy ? (
        status.stage === "issuing" ? (
          <p className="flex items-center gap-2 text-sm" role="status">
            <Loader2 className="size-4 animate-spin" aria-hidden /> {s.stages.issuing}
          </p>
        ) : (
          <DownloadBar label={`${s.stages[status.stage] ?? status.stage}${percent !== null ? ` ${percent}%` : ""}`} received={status.received} total={status.total} />
        )
      ) : status.serving && status.url ? (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <span className="font-medium text-emerald-600 dark:text-emerald-400">{s.serving}</span>
          <a href={status.url} target="_blank" rel="noreferrer" className="text-primary inline-flex items-center gap-1 font-mono break-all">
            {status.url}
            <ExternalLink className="size-3.5" aria-hidden />
          </a>
          {days !== null ? <span className={days < 14 ? "text-warning" : "text-muted-foreground"}>{s.expiresIn(days)}</span> : null}
        </div>
      ) : (
        <p className="text-sm font-medium">{status.enabled && !status.certificate ? s.noCertificate : s.off}</p>
      )}
      {status.stage === "failed" && status.error ? (
        <p className="text-destructive mt-2 text-xs break-words" role="alert">
          {s.failed}：{status.error}
        </p>
      ) : null}
      {status.enabled ? (
        <div className="mt-3 flex flex-wrap gap-2">
          {status.certificate ? (
            <Button size="sm" variant="outline" disabled={busy || issue.isPending} onClick={() => issue.mutate(undefined, { onError: fail })}>
              {s.renew}
            </Button>
          ) : null}
          <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setConfirming(true)}>
            {s.disable}
          </Button>
        </div>
      ) : null}
      <p className="text-muted-foreground mt-2 text-xs">{s.tool(status.toolVersion, status.toolInstalled)}</p>

      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.disableTitle}</AlertDialogTitle>
            <AlertDialogDescription>{s.disableHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => disable.mutate(undefined, { onError: fail })}>{s.disableConfirm}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function SettingsForm({ status, providers }: { status: TlsStatus; providers: TlsProvider[] }) {
  const save = useSaveTls();
  const issue = useIssueTls();
  const [domains, setDomains] = useState(status.domains.join(", "));
  const [providerCode, setProviderCode] = useState<string | null>(status.provider);
  const [typed, setTyped] = useState<Record<string, string>>({});
  const [cleared, setCleared] = useState<string[]>([]);
  const [directory, setDirectory] = useState(status.directory);
  const [email, setEmail] = useState(status.email);
  const [port, setPort] = useState(String(status.port));
  const [redirect, setRedirect] = useState(status.redirect);

  // a saved provider's stored names stay with it; another provider starts empty
  useEffect(() => {
    setTyped({});
    setCleared([]);
  }, [providerCode]);

  const provider = providers.find((p) => p.code === providerCode) ?? null;
  const stored = providerCode === status.provider ? status.envSet : [];
  const busy = tlsBusy(status.stage) || save.isPending || issue.isPending;

  const input = (enabled: boolean) => ({
    enabled,
    domains: parseDomains(domains),
    provider: providerCode,
    directory,
    email: email.trim(),
    port: Number.parseInt(port, 10),
    redirect,
    env: envInput(typed, cleared),
  });

  const saveOnly = () =>
    save.mutate(input(status.enabled), {
      onSuccess: () => {
        setTyped({});
        setCleared([]);
        toast.success(s.saved);
      },
      onError: fail,
    });

  const saveAndIssue = () =>
    save.mutate(input(true), {
      onSuccess: () => {
        setTyped({});
        setCleared([]);
        issue.mutate(undefined, { onError: fail });
      },
      onError: fail,
    });

  const names = parseDomains(domains);

  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-1.5">
        <Label htmlFor="tls-domains">{s.domains}</Label>
        <Input id="tls-domains" value={domains} onChange={(e) => setDomains(e.target.value)} placeholder="lx.example.com" autoCapitalize="none" spellCheck={false} />
        <p className="text-muted-foreground text-xs">{s.domainsHint}</p>
        <p className="text-muted-foreground text-xs">{s.aRecord(status.addresses.join("、") || "—")}</p>
        {status.resolution.length > 0 && names.length > 0 ? (
          <ul className="flex flex-col gap-0.5 text-xs" data-testid="tls-resolution">
            {status.resolution.map((r) => (
              <li key={r.domain} className="flex items-center gap-1.5">
                {r.here ? <Check className="size-3.5 text-emerald-600" aria-hidden /> : <X className="text-warning size-3.5" aria-hidden />}
                <code className="font-mono">{r.domain}</code>
                <span className={r.here ? "text-muted-foreground" : "text-warning"}>
                  {r.here ? s.resolvesHere : r.addresses.length > 0 ? s.resolvesElsewhere(r.addresses.join("、")) : s.unresolved}
                </span>
              </li>
            ))}
          </ul>
        ) : null}
      </div>

      <div className="grid gap-1.5">
        <Label id="tls-provider-label">{s.provider}</Label>
        <ProviderPicker providers={providers} value={providerCode} onChange={setProviderCode} />
      </div>

      {provider ? (
        <div className="grid gap-3" data-testid="tls-credentials">
          <div>
            <p className="text-sm font-medium">{s.credentials}</p>
            <p className="text-muted-foreground text-xs">{s.credentialsHint}</p>
          </div>
          {provider.credentials.map((v) => (
            <VariableField
              key={v.name}
              name={v.name}
              description={v.description}
              secret
              stored={stored.includes(v.name)}
              cleared={cleared.includes(v.name)}
              value={typed[v.name] ?? ""}
              onChange={(value) => setTyped((prev) => ({ ...prev, [v.name]: value }))}
              onClear={() => setCleared((prev) => (prev.includes(v.name) ? prev : [...prev, v.name]))}
            />
          ))}
        </div>
      ) : null}

      <Collapsible>
        <CollapsibleTrigger asChild>
          <Button variant="ghost" size="sm" className="-ml-2 w-fit">
            {s.more} <ChevronsUpDown className="size-3.5" />
          </Button>
        </CollapsibleTrigger>
        <CollapsibleContent className="mt-3 grid gap-4">
          <div className="grid gap-1.5">
            <Label>{s.directory}</Label>
            <Select value={directory} onValueChange={setDirectory}>
              <SelectTrigger className="h-10 w-full" aria-label={s.directory}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {Object.entries(s.directories).map(([value, label]) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
                {directory in s.directories ? null : <SelectItem value={directory}>{directory}</SelectItem>}
              </SelectContent>
            </Select>
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="tls-email">{s.email}</Label>
            <Input id="tls-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoCapitalize="none" />
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="tls-port">{s.port}</Label>
            <Input id="tls-port" inputMode="numeric" value={port} onChange={(e) => setPort(e.target.value.replace(/\D/g, ""))} className="w-32" />
            <p className="text-muted-foreground text-xs">{s.portHint(status.httpPort ?? null)}</p>
          </div>
          <div className="grid gap-1">
            <div className="flex items-center gap-3">
              <Switch id="tls-redirect" checked={redirect} onCheckedChange={setRedirect} />
              <Label htmlFor="tls-redirect">{s.redirect}</Label>
            </div>
            <p className="text-muted-foreground text-xs">{s.redirectHint(status.httpPort ?? null)}</p>
          </div>
          {provider && provider.additional.length > 0 ? (
            <div className="grid gap-3">
              <p className="text-sm font-medium">{s.additional}</p>
              {provider.additional.map((v) => (
                <VariableField
                  key={v.name}
                  name={v.name}
                  description={v.description}
                  stored={stored.includes(v.name)}
                  cleared={cleared.includes(v.name)}
                  value={typed[v.name] ?? ""}
                  onChange={(value) => setTyped((prev) => ({ ...prev, [v.name]: value }))}
                  onClear={() => setCleared((prev) => (prev.includes(v.name) ? prev : [...prev, v.name]))}
                />
              ))}
            </div>
          ) : null}
        </CollapsibleContent>
      </Collapsible>

      <div className="flex flex-wrap gap-2">
        <Button disabled={busy || names.length === 0 || !providerCode} onClick={saveAndIssue}>
          {s.saveAndIssue}
        </Button>
        <Button variant="outline" disabled={busy} onClick={saveOnly}>
          {s.save}
        </Button>
      </div>
    </div>
  );
}

function VariableField({
  name,
  description,
  secret = false,
  stored,
  cleared,
  value,
  onChange,
  onClear,
}: {
  name: string;
  description: string | null | undefined;
  secret?: boolean;
  stored: boolean;
  cleared: boolean;
  value: string;
  onChange: (value: string) => void;
  onClear: () => void;
}) {
  const id = `tls-var-${name}`;
  return (
    <div className="grid gap-1">
      <Label htmlFor={id} className="font-mono text-xs">
        {name}
      </Label>
      <div className="flex items-center gap-2">
        <Input
          id={id}
          type={secret ? "password" : "text"}
          autoComplete="off"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={stored && !cleared ? s.keepStored : ""}
          className="font-mono"
          spellCheck={false}
        />
        {stored && !cleared ? (
          <Button type="button" variant="ghost" size="sm" onClick={onClear}>
            {s.clearStored}
          </Button>
        ) : null}
      </div>
      {cleared ? <p className="text-warning text-xs">{s.cleared}</p> : description ? <p className="text-muted-foreground text-xs">{description}</p> : null}
    </div>
  );
}

// lego's 222 providers in a searchable list, the common ones first by their Chinese names
function ProviderPicker({ providers, value, onChange }: { providers: TlsProvider[]; value: string | null; onChange: (code: string) => void }) {
  const [open, setOpen] = useState(false);
  const featured = useMemo(
    () => FEATURED_PROVIDERS.map((f) => providers.find((p) => p.code === f.code)).filter((p): p is TlsProvider => !!p),
    [providers],
  );
  const rest = useMemo(
    () => providers.filter((p) => !FEATURED_PROVIDERS.some((f) => f.code === p.code)).sort((a, b) => a.name.localeCompare(b.name)),
    [providers],
  );
  const selected = providers.find((p) => p.code === value);
  const pick = (code: string) => {
    onChange(code);
    setOpen(false);
  };
  const item = (p: TlsProvider) => (
    <CommandItem key={p.code} value={`${providerLabel(p)} ${p.name} ${p.code} ${p.aliases.join(" ")}`} onSelect={() => pick(p.code)}>
      <Check className={`size-4 ${p.code === value ? "opacity-100" : "opacity-0"}`} aria-hidden />
      <span>{providerLabel(p)}</span>
      <span className="text-muted-foreground ml-auto font-mono text-xs">{p.code}</span>
    </CommandItem>
  );
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="outline" role="combobox" aria-expanded={open} aria-label={s.provider} className="h-10 w-full justify-between font-normal">
          {selected ? providerLabel(selected) : <span className="text-muted-foreground">{s.chooseProvider}</span>}
          <ChevronsUpDown className="size-4 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-(--radix-popover-trigger-width) p-0" align="start">
        <Command>
          <CommandInput placeholder={s.providerSearch} />
          <CommandList>
            <CommandEmpty>{s.providerNone}</CommandEmpty>
            <CommandGroup heading={s.featured}>{featured.map(item)}</CommandGroup>
            <CommandGroup heading={s.allProviders}>{rest.map(item)}</CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
