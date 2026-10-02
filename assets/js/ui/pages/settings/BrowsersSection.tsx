import { useTranslation } from "react-i18next";
// Settings → 浏览器: the person's browsers reached through the Longx Chrome
// extension — the extension to download and install unpacked, the pairing
// requests to allow, every paired browser (name, device, online, the tabs
// sessions hold in it, its tab limit), and
// the aliases a project's description names (`plug Browser, browser: "qa"`).
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";
import { CheckCircle2, Circle, Download } from "lucide-react";
import {
  type ChromeBrowser,
  useApproveBrowser,
  useChromeAliases,
  useChromeBrowsers,
  useChromeExtension,
  useDeleteChromeAlias,
  useRejectBrowser,
  useRenameBrowser,
  useRevokeBrowser,
  useSetBrowserMaxTabs,
  useSetChromeAlias,
  useSetChromeDefaultAlias,
} from "@/core/chrome";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.browsers;

export function BrowsersSection() {
  const browsers = useChromeBrowsers();
  if (browsers.isPending) return <Skeleton className="h-24 w-full" data-testid="section-browsers" />;
  if (browsers.isError) return <p className="text-destructive text-sm">{browsers.error.message}</p>;
  const pending = browsers.data.filter((b) => b.status === "pending");
  const paired = browsers.data.filter((b) => b.status !== "pending");
  return (
    <div className="flex flex-col gap-6" data-testid="section-browsers">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <p className="text-muted-foreground text-xs">{s.identityHint}</p>
      <ExtensionCard />
      {pending.length > 0 ? <PendingList browsers={pending} /> : null}
      <section className="flex flex-col gap-2">
        <h3 className="text-sm font-medium">{s.paired}</h3>
        {paired.length === 0 ? <p className="text-muted-foreground text-sm">{s.none}</p> : paired.map((b) => <BrowserRow key={b.id} browser={b} />)}
      </section>
      <AliasesCard browsers={paired} />
    </div>
  );
}

function ExtensionCard() {
  const ext = useChromeExtension();
  const origin = typeof window !== "undefined" ? window.location.origin : "";
  return (
    <section className="rounded-lg border p-3" data-testid="chrome-extension">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 className="text-sm font-medium">{s.extension}</h3>
          <p className="text-muted-foreground text-xs">
            {ext.data?.built ? s.extensionVersion(ext.data.version ?? "") : s.extensionNotBuilt} · {s.needsChrome(ext.data?.minimumChrome ?? "118")}
          </p>
        </div>
        {ext.data?.built ? (
          <Button asChild size="sm">
            <a href={ext.data.url} download>
              <Download className="size-4" /> {s.download}
            </a>
          </Button>
        ) : (
          <Button size="sm" disabled>
            <Download className="size-4" /> {s.download}
          </Button>
        )}
      </div>
      <ol className="text-muted-foreground mt-3 list-decimal space-y-1 ps-5 text-xs">
        {s.steps(origin).map((step, i) => (
          <li key={i}>{step}</li>
        ))}
      </ol>
    </section>
  );
}

function PendingList({ browsers }: { browsers: ChromeBrowser[] }) {
  const approve = useApproveBrowser();
  const reject = useRejectBrowser();
  const onError = (e: Error) => toast.error(e.message);
  return (
    <section className="border-warning/50 rounded-lg border p-3" data-testid="chrome-pending">
      <h3 className="text-sm font-medium">{s.pending}</h3>
      <p className="text-muted-foreground mb-2 text-xs">{s.pendingHint}</p>
      <ul className="divide-y">
        {browsers.map((b) => (
          <li key={b.id} className="flex flex-wrap items-center justify-between gap-2 py-2" data-testid="pending-row">
            <div className="min-w-0">
              <p className="truncate text-sm font-medium">{b.name}</p>
              <p className="text-muted-foreground text-xs">{deviceLine(b)}</p>
              <BrowserIdentity browser={b} />
              <p className="text-muted-foreground text-xs">{b.connected ? s.online : s.offline}</p>
            </div>
            <div className="flex gap-2">
              <Button size="sm" onClick={() => approve.mutate(b.id, { onError })} disabled={approve.isPending || !b.connected}>
                {s.allow}
              </Button>
              <Button size="sm" variant="outline" onClick={() => reject.mutate(b.id, { onError })} disabled={reject.isPending}>
                {s.reject}
              </Button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

function deviceLine(b: ChromeBrowser) {
  const parts = [b.device?.platform, b.device?.extension ? t.extensionVersionLabel(b.device.extension) : null].filter(Boolean);
  return parts.join(" · ");
}

function BrowserIdentity({ browser: b }: { browser: ChromeBrowser }) {
  return (
    <div className="text-muted-foreground flex flex-wrap gap-x-4 gap-y-1 text-xs">
      <span>{s.peerIp}: <code>{b.device?.peerIp ?? s.unknownIp}</code></span>
      <span className="break-all">{s.deviceId}: <code>{b.id}</code></span>
      {b.lastSeenAt ? <span>{s.lastSeen}: {new Date(b.lastSeenAt).toLocaleString()}</span> : null}
    </div>
  );
}

function browserLabel(b: ChromeBrowser) {
  return `${b.name} · ${b.device?.peerIp ?? s.unknownIp} · ID …${b.id.slice(-8)} · ${b.status === "revoked" ? s.revoked : b.connected ? s.online : s.offline}`;
}

function BrowserRow({ browser: b }: { browser: ChromeBrowser }) {
    useTranslation();
  const rename = useRenameBrowser();
  const limit = useSetBrowserMaxTabs();
  const revoke = useRevokeBrowser();
  const [name, setName] = useState(b.name);
  const [maxTabs, setMaxTabs] = useState(String(b.maxTabs));
  const [revoking, setRevoking] = useState(false);
  useEffect(() => setName(b.name), [b.name]);
  useEffect(() => setMaxTabs(String(b.maxTabs)), [b.maxTabs]);
  const onError = (e: Error) => toast.error(e.message);
  const online = b.status === "approved" && b.connected;
  return (
    <div className="flex flex-col gap-3 rounded-lg border p-3" data-testid="browser-row">
      <div className="flex flex-wrap items-center gap-2">
        {online ? <CheckCircle2 className="text-success size-4" /> : <Circle className="text-muted-foreground size-4" />}
        <Input
          aria-label={s.name}
          className="h-8 max-w-56 text-sm"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onBlur={() => name.trim() && name !== b.name && rename.mutate({ id: b.id, name: name.trim() }, { onError })}
        />
        <span className={online ? "text-success text-xs" : "text-muted-foreground text-xs"}>{b.status === "revoked" ? s.revoked : online ? s.online : s.offline}</span>
        <span className="text-muted-foreground text-xs">{deviceLine(b)}</span>
        {b.aliases.length > 0 ? (
          <span className="text-muted-foreground text-xs">
            {s.aliasesOf}{" "}
            {b.aliases.map((a) => (
              <code key={a} className="bg-muted me-1 rounded px-1 font-mono">
                {a}
              </code>
            ))}
          </span>
        ) : null}
        <Button size="sm" variant="ghost" className="ms-auto" onClick={() => setRevoking(true)} disabled={b.status === "revoked"}>
          {s.revoke}
        </Button>
      </div>
      <BrowserIdentity browser={b} />
      {!online && b.status === "approved" ? <p className="text-muted-foreground text-xs">{s.reconnectHint}</p> : null}
      <div className="text-muted-foreground flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
        <label className="flex items-center gap-1">
          {s.maxTabs}
          <Input
            aria-label={s.maxTabs}
            type="number"
            min={1}
            max={100}
            className="h-7 w-16 text-xs"
            value={maxTabs}
            onChange={(e) => setMaxTabs(e.target.value)}
            onBlur={() => {
              const n = Number(maxTabs);
              if (Number.isInteger(n) && n > 0 && n !== b.maxTabs) limit.mutate({ id: b.id, maxTabs: n }, { onError });
            }}
          />
        </label>
        {b.tabs.length > 0 ? (
          <span>
            {s.inUse}{" "}
            {b.tabs.map((x) => (
              <Link key={x.threadId} to="#" className="text-primary me-2 hover:underline">
                {x.title} · {s.tabCount(x.tabs)}
              </Link>
            ))}
          </span>
        ) : (
          <span>{s.noTabs}</span>
        )}
      </div>
      <AlertDialog open={revoking} onOpenChange={setRevoking}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.revokeTitle(b.name)}</AlertDialogTitle>
            <AlertDialogDescription>{s.revokeHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => revoke.mutate(b.id, { onError })}>{s.revokeConfirm}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function AliasesCard({ browsers }: { browsers: ChromeBrowser[] }) {
    useTranslation();
  const aliases = useChromeAliases();
  const save = useSetChromeAlias();
  const remove = useDeleteChromeAlias();
  const setDefault = useSetChromeDefaultAlias();
  const [name, setName] = useState("");
  const [picked, setPicked] = useState<string[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const onError = (e: Error) => toast.error(e.message);
  const toggle = (id: string) => setPicked((p) => (p.includes(id) ? p.filter((x) => x !== id) : [...p, id]));
  const duplicate = editing === null && aliases.data?.aliases.some((a) => a.name === name.trim());
  const valid = /^[\p{L}\p{N}_-]+$/u.test(name.trim()) && !duplicate && picked.length > 0
    && picked.every((id) => browsers.some((b) => b.id === id && b.status === "approved"));
  const reset = () => { setName(""); setPicked([]); setEditing(null); };
  return (
    <section className="flex flex-col gap-2 rounded-lg border p-3" data-testid="chrome-aliases">
      <h3 className="text-sm font-medium">{s.aliases}</h3>
      <p className="text-muted-foreground text-xs">{s.aliasesHint}</p>
      {aliases.data?.aliases.length ? (
        <ul className="divide-y">
          {aliases.data.aliases.map((a) => (
            <li key={a.name} className="flex flex-wrap items-center gap-2 py-2 text-sm" data-testid="alias-row">
              <code className="bg-muted rounded px-1.5 py-0.5 font-mono text-xs">{a.name}</code>
              <span className="text-muted-foreground text-xs">→ {a.browsers.map((id) => {
                const b = browsers.find((b) => b.id === id);
                return b ? browserLabel(b) : id;
              }).join(", ") || s.aliasEmpty}</span>
              <span className="text-muted-foreground text-xs">{s.aliasTarget}: {(() => {
                const target = a.browsers.map((id) => browsers.find((b) => b.id === id))
                  .find((b) => b?.status === "approved" && b.connected);
                return target ? browserLabel(target) : s.aliasOffline;
              })()}</span>
              <label className="text-muted-foreground ms-auto flex items-center gap-1 text-xs">
                <input type="radio" name="chrome-default-alias" checked={aliases.data?.default === a.name} onChange={() => setDefault.mutate(a.name, { onError })} />
                {s.default}
              </label>
              <Button size="sm" variant="outline" onClick={() => { setEditing(a.name); setName(a.name); setPicked(a.browsers); }}>
                {s.editAlias}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => remove.mutate(a.name, { onError })}>
                {t.delete}
              </Button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-muted-foreground text-sm">{s.noAliases}</p>
      )}
      <form
        className="mt-1 flex flex-wrap items-center gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          if (!valid) return;
          save.mutate(
            { name: name.trim(), browsers: picked },
            {
              onError,
              onSuccess: () => {
                reset();
              },
            },
          );
        }}
      >
        <Input aria-label={s.aliasName} placeholder={s.aliasName} className="h-8 max-w-40 text-sm" value={name} readOnly={editing !== null} onChange={(e) => setName(e.target.value)} />
        {browsers.filter((b) => b.status === "approved" || picked.includes(b.id)).map((b) => (
          <label key={b.id} className="flex items-center gap-1 text-xs">
            <input type="checkbox" checked={picked.includes(b.id)} onChange={() => toggle(b.id)} /> {picked.includes(b.id) ? `${picked.indexOf(b.id) + 1}. ` : ""}{browserLabel(b)}
          </label>
        ))}
        {picked.filter((id) => !browsers.some((b) => b.id === id)).map((id) => (
          <label key={id} className="text-destructive flex items-center gap-1 break-all text-xs">
            <input type="checkbox" checked onChange={() => toggle(id)} /> {id} · {s.aliasEmpty}
          </label>
        ))}
        <Button type="submit" size="sm" variant="outline" disabled={!valid || save.isPending}>
          {s.saveAlias}
        </Button>
        {editing !== null ? <Button type="button" variant="ghost" size="sm" onClick={reset}>{s.cancelAlias}</Button> : null}
      </form>
      {duplicate ? <p className="text-destructive text-xs">{s.aliasExists}</p> : null}
      <p className="text-muted-foreground text-xs">{s.aliasOrder}</p>
      {picked.length > 0 ? <p className="text-muted-foreground break-all text-xs">{s.aliasSelection}: {picked.map((id) => {
        const b = browsers.find((b) => b.id === id);
        return b ? browserLabel(b) : id;
      }).join(" → ")}</p> : null}
    </section>
  );
}
