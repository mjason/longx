// Settings → 工具: the registry's catalogue with a switch per tool, and the
// built-in browser's one setting.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { browserSettings, setBrowserPrivateNetwork } from "@/ash_rpc";
import { useAiActions, useTools } from "@/core/ai";
import { unwrap } from "@/core/projects";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

const browserKey = ["browser-settings"] as const;

/** the built-in browser: whether it may fetch private / loopback addresses */
function BrowserCard() {
  const client = useQueryClient();
  const settings = useQuery({
    queryKey: browserKey,
    queryFn: async () => unwrap(await browserSettings({ fields: ["allowPrivateNetwork", "available"] })),
  });
  const set = useMutation({
    mutationFn: async (enabled: boolean) => unwrap(await setBrowserPrivateNetwork({ fields: ["allowPrivateNetwork", "available"], input: { enabled } })),
    onSuccess: (data) => client.setQueryData(browserKey, data),
    onError: (e) => toast.error(e.message),
  });
  const s = t.toolsPage;
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

export function ToolsSection() {
  const tools = useTools();
  const actions = useAiActions();
  if (tools.isPending) return <Skeleton className="h-24 w-full" data-testid="section-tools" />;
  if (tools.isError) return <p className="text-destructive text-sm">{tools.error.message}</p>;
  return (
    <div className="flex flex-col gap-3" data-testid="section-tools">
      <BrowserCard />
      <p className="text-muted-foreground text-sm">{t.toolsPage.hint}</p>
      {tools.data.length === 0 ? <p className="text-muted-foreground text-sm">{t.toolsPage.empty}</p> : null}
      <ul className="divide-y rounded-lg border">
        {tools.data.map((tool) => (
          <li key={tool.id} className="flex items-center justify-between gap-4 px-3 py-3" data-testid={`tool-${tool.qualifiedName}`}>
            <div className="min-w-0">
              <label htmlFor={`tool-${tool.id}`} className="font-mono text-sm">
                {tool.qualifiedName}
              </label>
              <p className="text-muted-foreground mt-0.5 text-xs">{tool.description}</p>
            </div>
            <Switch
              id={`tool-${tool.id}`}
              checked={tool.enabled}
              aria-label={tool.qualifiedName}
              onCheckedChange={(enabled) => actions.setToolEnabled.mutate({ id: tool.id, enabled }, { onError: (e) => toast.error(e.message) })}
            />
          </li>
        ))}
      </ul>
    </div>
  );
}
