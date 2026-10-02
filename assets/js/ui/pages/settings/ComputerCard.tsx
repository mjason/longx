import { useState } from "react";
import { toast } from "sonner";
import { useComputerSettings, useComputerConfigure, useComputerConnection, useComputerConnectionActions } from "@/core/computer";
import { Button } from "@/ui/components/ui/button";
import { Checkbox } from "@/ui/components/ui/checkbox";
import { Input } from "@/ui/components/ui/input";
import { t } from "@/ui/strings";

export function ComputerCard() {
  const settings = useComputerSettings();
  const configure = useComputerConfigure();
  const status = useComputerConnection();
  const { connect, disconnect } = useComputerConnectionActions();
  const [url, setUrl] = useState<string | null>(null);
  const [token, setToken] = useState("");
  const [foreground, setForeground] = useState(false);
  const s = t.computer;
  const st = status.data;
  const active = st?.phase === "ready";
  const pending = st?.phase === "connecting" || connect.isPending || disconnect.isPending;
  const fail = (error: Error) => toast.error(error.message);
  let missingPermissions = false;
  try {
    const permissions = JSON.parse(st?.permissions || "{}");
    missingPermissions = permissions.accessibility === false || permissions.screen_recording === false;
  } catch { /* Unknown is not an authorization grant. */ }
  return (
    <section className="rounded-lg border p-3" data-testid="computer-settings">
      <h3 className="text-sm font-medium">{s.title}</h3>
      <p className="text-muted-foreground mt-1 text-xs">{s.serviceHint}</p>
      {settings.isError ? <p role="alert" className="text-destructive text-xs">{settings.error.message}</p> : null}
      <form className="mt-3 space-y-3" onSubmit={(event) => {
        event.preventDefault();
        configure.mutate({ url: url ?? settings.data?.url ?? "", token }, {
          onSuccess: () => { setToken(""); toast.success(s.saved); }, onError: fail,
        });
      }}>
        <label className="block text-xs">{s.serviceUrl}
          <Input className="mt-1" value={url ?? settings.data?.url ?? "http://127.0.0.1:7797/mcp"}
            onChange={(event) => setUrl(event.target.value)} required placeholder="http://127.0.0.1:7797/mcp" />
        </label>
        <label className="block text-xs">{s.accessKey}
          <Input className="mt-1" type="password" autoComplete="new-password" value={token}
            onChange={(event) => setToken(event.target.value)}
            placeholder={settings.data?.hasToken ? s.keySaved : s.keyRequired} />
        </label>
        <p className="text-muted-foreground text-xs">{s.keyHint}</p>
        <Button type="submit" size="sm" variant="outline" disabled={settings.isPending || configure.isPending}>{s.save}</Button>
      </form>
      <div className="mt-3 border-t pt-3" data-testid="computer-connection">
        {status.isError ? <p role="alert" className="text-destructive text-xs">{status.error.message}</p> : null}
        <div className="flex flex-wrap items-center gap-3">
          <p className={`text-xs ${active ? "text-success" : "text-muted-foreground"}`}>
            {active ? s.connected(st.toolCount) : pending ? s.connecting : s.disconnected}
          </p>
          {active || pending ? (
            <Button size="sm" variant="outline" disabled={disconnect.isPending}
              onClick={() => disconnect.mutate(undefined, { onError: fail })}>{s.disconnect}</Button>
          ) : (
            <Button size="sm" variant="outline" disabled={pending || !settings.data?.hasToken}
              onClick={() => connect.mutate(foreground, { onError: fail })}>{s.connect}</Button>
          )}
        </div>
        {st?.error ? <p role="alert" className="text-destructive mt-2 text-xs">{st.error}</p> : null}
        <label className="mt-3 flex items-start gap-2 text-xs">
          <Checkbox checked={active ? st.foreground : foreground} disabled={active || pending}
            onCheckedChange={(value) => setForeground(value === true)} />
          <span>{s.foreground}<span className="text-muted-foreground mt-1 block">{s.serviceForegroundHint}</span></span>
        </label>
        {active && missingPermissions ? <p role="alert" className="text-warning mt-2 text-xs">{s.servicePermissionsMissing}</p> : null}
        {st?.permissions && st.permissions !== "{}" ? <p className="text-muted-foreground mt-2 break-all font-mono text-xs">{s.permissions}: {st.permissions}</p> : null}
        {st?.busy && active ? <p className="text-warning mt-2 text-xs">{s.busy}</p> : null}
      </div>
      <p className="text-muted-foreground mt-3 text-xs">{s.serviceScope}</p>
      <p className="text-muted-foreground mt-2 text-xs">{s.plugHint}</p>
    </section>
  );
}
