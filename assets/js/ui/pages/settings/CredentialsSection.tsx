// Settings → 凭证: the API keys and OAuth2 tokens Longx keeps for the
// agent — listed with kind / status / hosts / expiry and never a value;
// added with the value (an API key) or the client (OAuth2), logged in
// through this browser (the redirect URI shown for the provider's
// console), refreshed by hand, deleted behind a confirm.
import { useState } from "react";
import { KeyRound, LogIn, RefreshCw, Trash2 } from "lucide-react";
import { toast } from "sonner";
import {
  splitHosts,
  useCredentialActions,
  useCredentials,
  useRedirectUri,
  type Credential,
} from "@/core/credentials";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
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
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/components/ui/dialog";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { Textarea } from "@/ui/components/ui/textarea";
import { t } from "@/ui/strings";

const s = t.credentialsPage;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

function browserOrigin(): string | null {
  return typeof window !== "undefined" && window.location?.origin ? window.location.origin : null;
}

export function CredentialsSection() {
  // a login in flight: the list polls until the browser comes back
  const [loginStartedAt, setLoginStartedAt] = useState<number | null>(null);
  const polling = loginStartedAt !== null && Date.now() - loginStartedAt < 10 * 60_000;
  const list = useCredentials({ refetchInterval: polling ? 3_000 : false });
  const redirect = useRedirectUri(browserOrigin());
  const [adding, setAdding] = useState<"api_key" | "oauth2" | null>(null);

  return (
    <div className="flex flex-col gap-4" data-testid="section-credentials">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <div className="rounded-lg border p-3 text-sm">
        <p className="text-muted-foreground mb-1 text-xs">{s.redirectHint}</p>
        <code className="break-all font-mono text-xs" data-testid="credentials-redirect-uri">
          {redirect.data ?? "…"}
        </code>
      </div>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" onClick={() => setAdding("api_key")}>
          <KeyRound className="size-4" /> {s.addApiKey}
        </Button>
        <Button size="sm" variant="outline" onClick={() => setAdding("oauth2")}>
          <LogIn className="size-4" /> {s.addOauth2}
        </Button>
      </div>
      {list.isPending ? (
        <Skeleton className="h-24 w-full" />
      ) : list.isError ? (
        <p className="text-destructive text-sm">{list.error.message}</p>
      ) : list.data.length === 0 ? (
        <p className="text-muted-foreground text-sm">{s.none}</p>
      ) : (
        <ul className="flex flex-col gap-3" data-testid="credentials-list">
          {list.data.map((c) => (
            <CredentialCard key={c.id} credential={c} onLoginStarted={() => setLoginStartedAt(Date.now())} />
          ))}
        </ul>
      )}
      {adding ? <AddDialog kind={adding} onClose={() => setAdding(null)} /> : null}
    </div>
  );
}

function statusTone(status: Credential["status"]): "default" | "secondary" | "destructive" | "outline" {
  switch (status) {
    case "ready":
      return "default";
    case "error":
      return "destructive";
    case "expired":
      return "secondary";
    default:
      return "outline";
  }
}

function CredentialCard({ credential: c, onLoginStarted }: { credential: Credential; onLoginStarted: () => void }) {
  const actions = useCredentialActions();
  const [confirming, setConfirming] = useState(false);

  const login = async () => {
    try {
      const { url } = await actions.loginUrl.mutateAsync({ id: c.id, origin: browserOrigin() });
      window.open(url, "_blank", "noopener,noreferrer");
      onLoginStarted();
      toast.message(s.loginStarted);
    } catch (e) {
      fail(e);
    }
  };

  return (
    <li className="rounded-lg border p-3" data-testid={`credential-${c.name}`}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm font-medium">{c.name}</span>
        {c.label ? <span className="text-muted-foreground text-sm">{c.label}</span> : null}
        <Badge variant="outline">{s.kind[c.kind] ?? c.kind}</Badge>
        <Badge variant={statusTone(c.status)} data-testid="credential-status">
          {c.status ? (s.status[c.status] ?? c.status) : "—"}
        </Badge>
      </div>
      <p className="text-muted-foreground mt-1 text-xs">
        {s.hosts}: {c.allowedHosts.join(", ")}
        {c.expiresAt ? ` · ${s.expires(new Date(c.expiresAt).toLocaleString())}` : ""}
      </p>
      {c.lastError ? <p className="text-destructive mt-1 text-xs">{c.lastError}</p> : null}
      <div className="mt-2 flex flex-wrap gap-2">
        {c.kind === "oauth2" ? (
          <Button size="sm" variant="outline" onClick={login} disabled={actions.loginUrl.isPending}>
            <LogIn className="size-4" /> {s.login}
          </Button>
        ) : null}
        {c.kind === "oauth2" && c.hasRefreshToken ? (
          <Button
            size="sm"
            variant="outline"
            disabled={actions.refresh.isPending}
            onClick={() =>
              actions.refresh.mutate(c.id, { onSuccess: () => toast.success(s.refreshed), onError: fail })
            }
          >
            <RefreshCw className={`size-4 ${actions.refresh.isPending ? "animate-spin" : ""}`} /> {s.refresh}
          </Button>
        ) : null}
        <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setConfirming(true)}>
          <Trash2 className="size-4" /> {s.delete}
        </Button>
      </div>
      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.deleteConfirm(c.name)}</AlertDialogTitle>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{s.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => actions.remove.mutate(c.id, { onError: fail })}>
              {s.delete}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </li>
  );
}

type Form = {
  name: string;
  label: string;
  hosts: string;
  header: string;
  scheme: string;
  secret: string;
  authorizeUrl: string;
  tokenUrl: string;
  registrationUrl: string;
  scopes: string;
  clientId: string;
  clientSecret: string;
  pkce: boolean;
};

const EMPTY: Form = {
  name: "",
  label: "",
  hosts: "",
  header: "authorization",
  scheme: "Bearer",
  secret: "",
  authorizeUrl: "",
  tokenUrl: "",
  registrationUrl: "",
  scopes: "",
  clientId: "",
  clientSecret: "",
  pkce: true,
};

function AddDialog({ kind, onClose }: { kind: "api_key" | "oauth2"; onClose: () => void }) {
  const actions = useCredentialActions();
  const [form, setForm] = useState<Form>(EMPTY);
  const set = (key: keyof Form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));
  const busy = actions.createApiKey.isPending || actions.createOauth2.isPending;
  const hosts = splitHosts(form.hosts);
  const valid =
    form.name.trim() !== "" &&
    hosts.length > 0 &&
    (kind === "api_key" ? form.secret !== "" : form.clientId !== "" || form.registrationUrl !== "");

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const common = {
      name: form.name.trim(),
      allowedHosts: hosts,
      ...(form.label ? { label: form.label } : {}),
      ...(form.header && form.header !== "authorization" ? { header: form.header } : {}),
      ...(form.scheme !== "Bearer" ? { scheme: form.scheme } : {}),
    };
    try {
      if (kind === "api_key") {
        await actions.createApiKey.mutateAsync({ ...common, secret: form.secret });
      } else {
        await actions.createOauth2.mutateAsync({
          ...common,
          ...(form.authorizeUrl ? { authorizeUrl: form.authorizeUrl } : {}),
          ...(form.tokenUrl ? { tokenUrl: form.tokenUrl } : {}),
          ...(form.registrationUrl ? { registrationUrl: form.registrationUrl } : {}),
          ...(form.scopes ? { scopes: form.scopes } : {}),
          ...(form.clientId ? { clientId: form.clientId } : {}),
          ...(form.clientSecret ? { clientSecret: form.clientSecret } : {}),
          pkce: form.pkce,
        });
      }
      toast.success(s.created);
      onClose();
    } catch (e) {
      fail(e);
    }
  };

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{kind === "api_key" ? s.addApiKey : s.addOauth2}</DialogTitle>
        </DialogHeader>
        <form onSubmit={submit} className="flex min-h-0 flex-1 flex-col" data-testid="credential-form">
          <DialogBody className="flex flex-col gap-3">
            <Field label={s.name} hint={s.nameHint}>
              <Input value={form.name} onChange={set("name")} autoFocus aria-label={s.name} />
            </Field>
            <Field label={s.label}>
              <Input value={form.label} onChange={set("label")} aria-label={s.label} />
            </Field>
            <Field label={s.hostsField} hint={s.hostsHint}>
              <Textarea value={form.hosts} onChange={set("hosts")} rows={2} aria-label={s.hostsField} />
            </Field>
            {kind === "api_key" ? (
              <Field label={s.secret}>
                <Input type="password" value={form.secret} onChange={set("secret")} aria-label={s.secret} autoComplete="off" />
              </Field>
            ) : (
              <>
                <Field label={s.authorizeUrl}>
                  <Input value={form.authorizeUrl} onChange={set("authorizeUrl")} aria-label={s.authorizeUrl} />
                </Field>
                <Field label={s.tokenUrl}>
                  <Input value={form.tokenUrl} onChange={set("tokenUrl")} aria-label={s.tokenUrl} />
                </Field>
                <Field label={s.scopes}>
                  <Input value={form.scopes} onChange={set("scopes")} aria-label={s.scopes} />
                </Field>
                <Field label={s.clientId}>
                  <Input value={form.clientId} onChange={set("clientId")} aria-label={s.clientId} />
                </Field>
                <Field label={s.clientSecret}>
                  <Input type="password" value={form.clientSecret} onChange={set("clientSecret")} aria-label={s.clientSecret} autoComplete="off" />
                </Field>
                <Field label={s.registrationUrl} hint={s.registrationHint}>
                  <Input value={form.registrationUrl} onChange={set("registrationUrl")} aria-label={s.registrationUrl} />
                </Field>
                <div className="flex items-center justify-between">
                  <Label htmlFor="credential-pkce">{s.pkce}</Label>
                  <Switch id="credential-pkce" checked={form.pkce} onCheckedChange={(v) => setForm((f) => ({ ...f, pkce: v }))} />
                </div>
              </>
            )}
            <div className="grid grid-cols-2 gap-3">
              <Field label={s.header}>
                <Input value={form.header} onChange={set("header")} aria-label={s.header} />
              </Field>
              <Field label={s.scheme} hint={s.schemeHint}>
                <Input value={form.scheme} onChange={set("scheme")} aria-label={s.scheme} />
              </Field>
            </div>
          </DialogBody>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              {s.cancel}
            </Button>
            <Button type="submit" disabled={!valid || busy}>
              {s.save}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <Label>{label}</Label>
      {children}
      {hint ? <p className="text-muted-foreground text-xs">{hint}</p> : null}
    </div>
  );
}
