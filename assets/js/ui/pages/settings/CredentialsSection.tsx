// Settings → 凭证: the API keys and OAuth2 tokens Longx keeps for the
// agent — listed with kind / status / hosts / expiry and never a value;
// added with the value (an API key) or the client (OAuth2), logged in
// through this browser (the redirect URI shown for the provider's
// console), refreshed by hand, deleted behind a confirm.
import { useState } from "react";
import { KeyRound, LogIn, Pencil, RefreshCw, Trash2 } from "lucide-react";
import { ChatGptLoginDialog } from "./ChatGptLoginDialog";
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
      {adding ? <CredentialDialog kind={adding} onClose={() => setAdding(null)} /> : null}
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
  const [editing, setEditing] = useState(false);
  // a login on a loopback redirect: the browser may land on an unreachable
  // 127.0.0.1 page (it runs on another machine) — its address pasted here finishes it
  const [pasteFor, setPasteFor] = useState<string | null>(null);
  const [pasted, setPasted] = useState("");
  // a vendor with a device-code login (ChatGPT): the dialog with the code and the browser way
  const [deviceLogin, setDeviceLogin] = useState(false);

  const login = async () => {
    try {
      const { url, redirectUri, loopback } = await actions.loginUrl.mutateAsync({ id: c.id, origin: browserOrigin() });
      window.open(url, "_blank", "noopener,noreferrer");
      onLoginStarted();
      setPasteFor(loopback ? redirectUri : null);
      setPasted("");
      toast.message(loopback ? s.loginStartedLoopback : s.loginStarted);
    } catch (e) {
      fail(e);
    }
  };
  const complete = async () => {
    try {
      await actions.completeUrl.mutateAsync(pasted.trim());
      setPasteFor(null);
      toast.success(s.loggedIn);
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
      {c.kind === "oauth2" ? (
        // what the agent may have got wrong is in plain view: the client, the endpoints
        <dl className="text-muted-foreground mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-xs">
          <dt>{s.clientId}</dt>
          <dd className="font-mono break-all">{c.clientId ?? (c.registrationUrl ? s.clientByRegistration : "—")}</dd>
          <dt>{s.authorizeUrl}</dt>
          <dd className="font-mono break-all">{c.authorizeUrl ?? "—"}</dd>
          <dt>{s.tokenUrl}</dt>
          <dd className="font-mono break-all">{c.tokenUrl ?? "—"}</dd>
          {c.scopes ? (
            <>
              <dt>{s.scopes}</dt>
              <dd className="font-mono break-all">{c.scopes}</dd>
            </>
          ) : null}
        </dl>
      ) : (
        <p className="text-muted-foreground mt-1 font-mono text-xs">
          {c.header}: {c.scheme ? `${c.scheme} ` : ""}••••
        </p>
      )}
      {c.lastError ? <p className="text-destructive mt-1 text-xs">{c.lastError}</p> : null}
      {pasteFor && c.status !== "ready" ? (
        <div className="bg-muted/40 mt-2 rounded-md border p-2 text-xs" data-testid="credential-paste">
          <p className="text-muted-foreground">{s.pasteHint(pasteFor)}</p>
          <div className="mt-1.5 flex gap-2">
            <Input value={pasted} onChange={(e) => setPasted(e.target.value)} aria-label={s.pasteLabel} placeholder={pasteFor + "?code=…"} className="font-mono text-xs" />
            <Button size="sm" disabled={pasted.trim() === "" || actions.completeUrl.isPending} onClick={complete}>
              {s.completeLogin}
            </Button>
          </div>
        </div>
      ) : null}
      <div className="mt-2 flex flex-wrap gap-2">
        <Button size="sm" variant="outline" onClick={() => setEditing(true)}>
          <Pencil className="size-4" /> {s.edit}
        </Button>
        {c.kind === "oauth2" && c.deviceFlow === "openai" ? (
          <Button size="sm" variant="outline" onClick={() => setDeviceLogin(true)}>
            <LogIn className="size-4" /> {s.login}
          </Button>
        ) : c.kind === "oauth2" ? (
          <Button size="sm" variant="outline" onClick={login} disabled={actions.loginUrl.isPending}>
            <LogIn className="size-4" /> {s.login}
          </Button>
        ) : null}
        {deviceLogin ? <ChatGptLoginDialog credentialId={c.id} onClose={() => setDeviceLogin(false)} /> : null}
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
      {editing ? <CredentialDialog credential={c} onClose={() => setEditing(false)} /> : null}
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
  // editing: drop the stored client secret (the client is public)
  clearClientSecret: boolean;
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
  clearClientSecret: false,
};

function formOf(c: Credential): Form {
  return {
    ...EMPTY,
    name: c.name,
    label: c.label ?? "",
    hosts: c.allowedHosts.join("\n"),
    header: c.header,
    scheme: c.scheme,
    authorizeUrl: c.authorizeUrl ?? "",
    tokenUrl: c.tokenUrl ?? "",
    registrationUrl: c.registrationUrl ?? "",
    scopes: c.scopes ?? "",
    clientId: c.clientId ?? "",
    pkce: c.pkce,
  };
}

// One form for a new credential (`kind`) and for editing one (`credential`):
// the agent writes most of these rows, and a wrong host, endpoint or client
// id is fixed here rather than by deleting and starting over. Editing keeps
// the name (what the agent's calls refer to) and the stored secrets unless a
// new one is typed.
function CredentialDialog(props: { kind: "api_key" | "oauth2"; onClose: () => void } | { credential: Credential; onClose: () => void }) {
  const { onClose } = props;
  const existing = "credential" in props ? props.credential : null;
  const kind = "credential" in props ? props.credential.kind : props.kind;
  const actions = useCredentialActions();
  const [form, setForm] = useState<Form>(() => (existing ? formOf(existing) : EMPTY));
  const set = (key: keyof Form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));
  const busy = actions.createApiKey.isPending || actions.createOauth2.isPending || actions.update.isPending;
  const hosts = splitHosts(form.hosts);
  const valid =
    form.name.trim() !== "" &&
    hosts.length > 0 &&
    (existing ? true : kind === "api_key" ? form.secret !== "" : form.clientId !== "" || form.registrationUrl !== "");

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      if (existing) {
        await actions.update.mutateAsync({
          id: existing.id,
          input: {
            allowedHosts: hosts,
            label: form.label,
            header: form.header || "authorization",
            scheme: form.scheme,
            ...(kind === "api_key"
              ? { ...(form.secret ? { secret: form.secret } : {}) }
              : {
                  authorizeUrl: form.authorizeUrl,
                  tokenUrl: form.tokenUrl,
                  registrationUrl: form.registrationUrl,
                  scopes: form.scopes,
                  clientId: form.clientId,
                  pkce: form.pkce,
                  ...(form.clearClientSecret ? { clientSecret: null } : form.clientSecret ? { clientSecret: form.clientSecret } : {}),
                }),
          },
        });
        toast.success(s.updated);
        onClose();
        return;
      }
      const common = {
        name: form.name.trim(),
        allowedHosts: hosts,
        ...(form.label ? { label: form.label } : {}),
        ...(form.header && form.header !== "authorization" ? { header: form.header } : {}),
        ...(form.scheme !== "Bearer" ? { scheme: form.scheme } : {}),
      };
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
          <DialogTitle>{existing ? s.editTitle(existing.name) : kind === "api_key" ? s.addApiKey : s.addOauth2}</DialogTitle>
        </DialogHeader>
        <form onSubmit={submit} className="flex min-h-0 flex-1 flex-col" data-testid="credential-form">
          <DialogBody className="flex flex-col gap-3">
            <Field label={s.name} hint={s.nameHint}>
              <Input value={form.name} onChange={set("name")} autoFocus={!existing} disabled={!!existing} aria-label={s.name} />
            </Field>
            <Field label={s.label}>
              <Input value={form.label} onChange={set("label")} aria-label={s.label} />
            </Field>
            <Field label={s.hostsField} hint={s.hostsHint}>
              <Textarea value={form.hosts} onChange={set("hosts")} rows={2} aria-label={s.hostsField} />
            </Field>
            {kind === "api_key" ? (
              <Field label={s.secret} hint={existing ? s.keepSecret : undefined}>
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
                <Field label={s.clientSecret} hint={existing && existing.hasClientSecret ? s.keepSecret : undefined}>
                  {existing?.hasClientSecret ? (
                    <div className="flex items-center justify-between py-1">
                      <Label htmlFor="credential-clear-secret" className="text-muted-foreground text-xs font-normal">
                        {s.clearClientSecret}
                      </Label>
                      <Switch
                        id="credential-clear-secret"
                        aria-label={s.clearClientSecret}
                        checked={form.clearClientSecret}
                        onCheckedChange={(v) => setForm((f) => ({ ...f, clearClientSecret: v, clientSecret: v ? "" : f.clientSecret }))}
                      />
                    </div>
                  ) : null}
                  <Input type="password" value={form.clientSecret} disabled={form.clearClientSecret} onChange={set("clientSecret")} aria-label={s.clientSecret} autoComplete="off" />
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
