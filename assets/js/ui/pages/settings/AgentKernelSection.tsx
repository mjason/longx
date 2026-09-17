// Settings → Agent 内核: the native kernel's team parameters (the topmost
// layer of every agent's description) and the person's global agent files.
import { useState } from "react";
import { toast } from "sonner";
import { useAgentSettings, useAgentSettingsActions, usePublicUrl, usePublicUrlActions } from "@/core/agent";
import { useModelRows } from "@/core/ai";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { browserSettings, setBrowserPrivateNetwork } from "@/ash_rpc";
import { unwrap } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { AgentSettingsFields, agentSettingsForm, agentSettingsInput, type AgentSettingsForm } from "@/ui/components/AgentSettingsFields";
import { t } from "@/ui/strings";

const s = t.agentKernel;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function AgentKernelSection() {
  return (
    <div className="flex flex-col gap-8" data-testid="section-agent">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <SettingsCard />
      <PublicUrlCard />
      <BrowserCard />
    </div>
  );
}

const browserKey = ["browser-settings"] as const;

/** the built-in browser (web_fetch, a search's page reads): whether it may fetch private / loopback addresses */
function BrowserCard() {
  const client = useQueryClient();
  const settings = useQuery({
    queryKey: browserKey,
    queryFn: async () => unwrap(await browserSettings({ fields: ["allowPrivateNetwork", "available"] })),
  });
  const set = useMutation({
    mutationFn: async (enabled: boolean) => unwrap(await setBrowserPrivateNetwork({ fields: ["allowPrivateNetwork", "available"], input: { enabled } })),
    onSuccess: (data) => client.setQueryData(browserKey, data),
    onError: fail,
  });
  return (
    <div className="rounded-lg border p-3" data-testid="browser-settings">
      <p className="text-sm font-medium">{s.browserTitle}</p>
      <p className="text-muted-foreground mt-0.5 text-xs">{settings.data?.available === false ? s.browserUnavailable : s.browserHint}</p>
      <div className="mt-3 flex items-start justify-between gap-4">
        <div className="min-w-0">
          <label htmlFor="browser-private-network" className="text-sm">
            {s.privateNetwork}
          </label>
          <p className="text-muted-foreground mt-0.5 text-xs">{s.privateNetworkHint}</p>
        </div>
        <Switch
          id="browser-private-network"
          aria-label={s.privateNetwork}
          checked={settings.data?.allowPrivateNetwork ?? false}
          disabled={settings.isPending || set.isPending}
          onCheckedChange={(v) => set.mutate(v)}
        />
      </div>
    </div>
  );
}

function SettingsCard() {
  const settings = useAgentSettings();
  const models = useModelRows();
  if (settings.isPending || models.isPending) return <Skeleton className="h-24 w-full" />;
  if (settings.isError) return <p className="text-destructive text-sm">{settings.error.message}</p>;
  return <SettingsForm key={JSON.stringify(settings.data)} initial={agentSettingsForm(settings.data)} models={models.data ?? []} />;
}

function SettingsForm({ initial, models }: { initial: AgentSettingsForm; models: ReturnType<typeof useModelRows>["data"] & object }) {
  const actions = useAgentSettingsActions();
  const [form, setForm] = useState(initial);
  const save = () => actions.save.mutateAsync(agentSettingsInput(form)).then(() => toast.success(s.saved), fail);
  return (
    <section className="space-y-4 rounded-lg border p-4" data-testid="agent-settings">
      <AgentSettingsFields idPrefix="ak" value={form} onChange={setForm} models={models} />
      <Button size="sm" onClick={save} disabled={actions.save.isPending}>{s.save}</Button>
    </section>
  );
}

function PublicUrlCard() {
  const current = usePublicUrl();
  const actions = usePublicUrlActions();
  const [draft, setDraft] = useState<string | null>(null);
  if (current.isPending) return <Skeleton className="h-16 w-full" />;
  if (current.isError) return <p className="text-destructive text-sm">{current.error.message}</p>;
  const value = draft ?? current.data.setting ?? "";
  const save = () => actions.save.mutateAsync(value).then(() => { toast.success(s.publicUrlSaved); setDraft(null); }, fail);
  return (
    <section className="space-y-2 rounded-lg border p-4" data-testid="public-url">
      <Label htmlFor="ak-public-url">{s.publicUrl}</Label>
      <div className="flex flex-wrap gap-2">
        <Input id="ak-public-url" value={value} placeholder={current.data.url} onChange={(e) => setDraft(e.target.value)} className="w-80 font-mono" />
        <Button size="sm" onClick={save} disabled={draft === null || actions.save.isPending}>{s.save}</Button>
      </div>
      <p className="text-muted-foreground text-xs">{s.publicUrlHint(current.data.url)}</p>
    </section>
  );
}
