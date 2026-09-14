// Settings → 工具: the registry's catalogue with a switch per tool.
import { toast } from "sonner";
import { useAiActions, useTools } from "@/core/ai";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

export function ToolsSection() {
  const tools = useTools();
  const actions = useAiActions();
  if (tools.isPending) return <Skeleton className="h-24 w-full" data-testid="section-tools" />;
  if (tools.isError) return <p className="text-destructive text-sm">{tools.error.message}</p>;
  return (
    <div className="flex flex-col gap-3" data-testid="section-tools">
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
