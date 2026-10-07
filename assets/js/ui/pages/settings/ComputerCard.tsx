import { useState } from "react";
import { useSettingsDraft } from "./SettingsDraft";
import { toast } from "sonner";
import { type ComputerDevice, useComputerDevices, useComputerAliases, useComputerDeviceActions } from "@/core/computer";
import { Button } from "@/ui/components/ui/button";
import { Checkbox } from "@/ui/components/ui/checkbox";
import { Input } from "@/ui/components/ui/input";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { t } from "@/ui/strings";

const fail = (error: Error) => toast.error(error.message);
export function ComputerCard() {
  const devices = useComputerDevices();
  const [adding, setAdding] = useState(false);
  const [newId, setNewId] = useState("");
  const s = t.computer;
  return (
    <section className="space-y-3 rounded-lg border p-3" data-testid="computer-settings">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-medium">{s.title}</h3>
        <Button size="sm" variant="outline" onClick={() => { setNewId(crypto.randomUUID()); setAdding(true); }}>{s.add}</Button>
      </div>
      <p className="text-muted-foreground text-xs">{s.serviceHint}</p>
      {devices.isError ? <p role="alert" className="text-destructive text-xs">{devices.error.message}</p> : null}
      {devices.isPending ? <p className="text-muted-foreground text-xs">{s.loading}</p> : null}
      {devices.data?.map((device) => <ComputerRow key={device.id} device={device} />)}
      {adding ? <ComputerEditor id={newId} onSaved={() => setAdding(false)} onCancel={() => setAdding(false)} /> : null}
      <AliasesCard devices={devices.data ?? []} />
      <p className="text-muted-foreground text-xs">{s.serviceScope}</p>
      <p className="text-muted-foreground text-xs">{s.multiPlugHint}</p>
    </section>
  );
}

function ComputerEditor({ id, device, onSaved, onCancel }: { id: string; device?: ComputerDevice; onSaved: () => void; onCancel?: () => void }) {
  const { save } = useComputerDeviceActions();
  const [name, setName] = useState(device?.name ?? "");
  const [url, setUrl] = useState(device?.url ?? "http://127.0.0.1:7797/mcp");
  const [token, setToken] = useState("");
  useSettingsDraft(name !== (device?.name ?? "") || url !== (device?.url ?? "http://127.0.0.1:7797/mcp") || token !== "");
  const s = t.computer;
  return (
    <form className="space-y-2" onSubmit={(event) => {
      event.preventDefault();
      save.mutate({ id, name: name.trim(), url: url.trim(), token }, {
        onSuccess: () => { setToken(""); toast.success(s.saved); onSaved(); }, onError: fail,
      });
    }}>
      <label className="block text-xs">{s.name}<Input value={name} onChange={(e) => setName(e.target.value)} required /></label>
      <label className="block text-xs">{s.serviceUrl}<Input value={url} onChange={(e) => setUrl(e.target.value)} required /></label>
      <label className="block text-xs">{s.accessKey}<Input type="password" autoComplete="new-password" value={token}
        onChange={(e) => setToken(e.target.value)} placeholder={device?.hasToken ? s.keySaved : s.keyRequired} /></label>
      <p className="text-muted-foreground text-xs">{s.keyHint}</p>
      <div className="flex gap-2">
        <Button type="submit" size="sm" variant="outline" disabled={save.isPending || !name.trim()}>{s.save}</Button>
        {onCancel ? <Button type="button" size="sm" variant="ghost" onClick={onCancel}>{t.cancel}</Button> : null}
      </div>
    </form>
  );
}

function ComputerRow({ device }: { device: ComputerDevice }) {
  const { connect, disconnect, remove } = useComputerDeviceActions();
  const [editing, setEditing] = useState(!device.hasToken);
  const [deleting, setDeleting] = useState(false);
  const [foreground, setForeground] = useState<boolean | null>(null);
  const st = device.connection;
  const active = st.phase === "ready";
  const pending = st.phase === "connecting" || connect.isPending || disconnect.isPending;
  const selected = foreground ?? st.foreground;
  const dirty = active && selected !== st.foreground;
  const s = t.computer;
  let missing = false;
  try {
    const permissions = JSON.parse(st.permissions || "{}");
    missing = permissions.accessibility === false || permissions.screen_recording === false;
  } catch { /* Unknown is not an authorization grant. */ }
  const apply = async () => {
    try {
      if (active) await disconnect.mutateAsync(device.id);
      await connect.mutateAsync({ id: device.id, foreground: selected });
    } catch (error) { fail(error as Error); }
  };
  return (
    <div className="space-y-2 rounded-lg border p-3" data-testid="computer-device">
      <div className="flex flex-wrap items-center gap-2">
        <h4 className="text-sm font-medium">{device.name}</h4>
        <span className={`text-xs ${active ? "text-success" : "text-muted-foreground"}`}>{active ? s.connected(st.toolCount) : pending ? s.connecting : s.disconnected}</span>
        <Button size="sm" variant="ghost" className="ms-auto" onClick={() => setEditing(!editing)}>{s.edit}</Button>
        <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setDeleting(true)}>{t.delete}</Button>
      </div>
      <p className="text-muted-foreground break-all text-xs">{device.url} · ID <code>{device.id}</code></p>
      {editing ? <ComputerEditor id={device.id} device={device} onSaved={() => setEditing(false)} /> : null}
      <div className="flex flex-wrap gap-2" data-testid="computer-connection">
        {active || pending ? <Button size="sm" variant="outline" disabled={disconnect.isPending} onClick={() => disconnect.mutate(device.id, { onError: fail })}>{s.disconnect}</Button> : null}
        {!active || dirty ? <Button size="sm" variant="outline" disabled={pending || !device.hasToken || (active && st.busy)} onClick={() => void apply()}>{dirty ? s.applyReconnect : s.connect}</Button> : null}
      </div>
      <label className="flex items-start gap-2 text-xs">
        <Checkbox checked={selected} disabled={pending} onCheckedChange={(value) => setForeground(value === true)} />
        <span>{s.foreground}<span className="text-muted-foreground mt-1 block">{s.serviceForegroundHint}</span></span>
      </label>
      {active && missing ? <p role="alert" className="text-warning text-xs">{s.servicePermissionsMissing}</p> : null}
      {st.error ? <p role="alert" className="text-destructive text-xs">{st.error}</p> : null}
      {st.permissions && st.permissions !== "{}" ? <p className="text-muted-foreground break-all font-mono text-xs">{s.permissions}: {st.permissions}</p> : null}
      {st.busy && active ? <p className="text-warning text-xs">{s.busy}</p> : null}
      <AlertDialog open={deleting} onOpenChange={setDeleting}>
        <AlertDialogContent><AlertDialogHeader><AlertDialogTitle>{s.deleteTitle(device.name)}</AlertDialogTitle>
          <AlertDialogDescription>{s.deleteHint}</AlertDialogDescription></AlertDialogHeader>
          <AlertDialogFooter><AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={() => remove.mutate(device.id, { onError: fail })}>{t.delete}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function AliasesCard({ devices }: { devices: ComputerDevice[] }) {
  const aliases = useComputerAliases();
  const actions = useComputerDeviceActions();
  const [name, setName] = useState("");
  const [picked, setPicked] = useState<string[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const s = t.computer;
  const reset = () => { setName(""); setPicked([]); setEditing(null); };
  const label = (id: string) => devices.find((d) => d.id === id)?.name ?? id;
  const duplicate = editing === null && aliases.data?.aliases.some((a) => a.name === name.trim());
  const valid = /^[\p{L}\p{N}_-]+$/u.test(name.trim()) && picked.length > 0 && !duplicate;
  return (
    <section className="space-y-2 border-t pt-3" data-testid="computer-aliases">
      <h4 className="text-sm font-medium">{s.aliases}</h4>
      <p className="text-muted-foreground text-xs">{s.aliasHint}</p>
      {aliases.isError ? <p role="alert" className="text-destructive text-xs">{aliases.error.message}</p> : null}
      {aliases.data?.aliases.map((alias) => {
        const target = alias.computers.find((id) => devices.find((d) => d.id === id)?.connection.phase === "ready");
        return <div key={alias.name} className="flex flex-wrap items-center gap-2 text-xs">
          <code>{alias.name}</code><span>→ {alias.computers.map(label).join(" → ")}</span>
          <span className="text-muted-foreground">{s.aliasTarget}: {target ? label(target) : s.aliasOffline}</span>
          <label className="ms-auto flex gap-1"><input type="radio" name="computer-default" checked={aliases.data?.default === alias.name}
            onChange={() => actions.defaultAlias.mutate(alias.name, { onError: fail })} />{s.default}</label>
          <Button size="sm" variant="ghost" onClick={() => { setEditing(alias.name); setName(alias.name); setPicked(alias.computers); }}>{s.edit}</Button>
          <Button size="sm" variant="ghost" onClick={() => actions.deleteAlias.mutate(alias.name, { onError: fail })}>{t.delete}</Button>
        </div>;
      })}
      <form className="flex flex-wrap items-center gap-2" onSubmit={(event) => {
        event.preventDefault();
        if (valid) actions.alias.mutate({ name: name.trim(), computers: picked }, { onSuccess: reset, onError: fail });
      }}>
        <Input aria-label={s.aliasName} placeholder={s.aliasName} className="max-w-40" value={name} readOnly={editing !== null} onChange={(e) => setName(e.target.value)} />
        {devices.map((d) => <label key={d.id} className="flex items-center gap-1 text-xs">
          <input type="checkbox" checked={picked.includes(d.id)} onChange={() => setPicked((prev) => prev.includes(d.id) ? prev.filter((id) => id !== d.id) : [...prev, d.id])} />
          {picked.includes(d.id) ? `${picked.indexOf(d.id) + 1}. ` : ""}{d.name}
        </label>)}
        <Button type="submit" size="sm" variant="outline" disabled={!valid || actions.alias.isPending}>{s.saveAlias}</Button>
        {editing ? <Button type="button" size="sm" variant="ghost" onClick={reset}>{t.cancel}</Button> : null}
      </form>
      {picked.length ? <p className="text-muted-foreground text-xs">{picked.map(label).join(" → ")}</p> : null}
    </section>
  );
}
