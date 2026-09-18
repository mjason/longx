// Watches — the scheduled scripts of a project (Longx.Watches): listed with
// their state for the project's settings page and the global overview,
// switched, dry-run, deleted. DOM-free.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { deleteWatch, dryRunWatch, listAllWatches, listWatches, switchWatch } from "@/ash_rpc";
import { unwrap } from "@/core/projects";

export type WatchKind = "cron" | "once" | "webhook";
export type WatchDisabledReason = "by_person" | "load_error" | "budget" | "expired" | "done";

export type Watch = {
  id: string;
  name: string;
  path: string;
  layer: "local" | "project";
  kind: WatchKind;
  cron: string | null;
  at: string | null;
  enabled: boolean;
  disabledReason: WatchDisabledReason | null;
  loadError: string | null;
  nextDueAt: string | null;
  runningSince: string | null;
  lastRunAt: string | null;
  lastDurationMs: number | null;
  lastError: string | null;
  lastOutput: string | null;
  lastSentTo: string | null;
  runs: number;
  sends: number;
  webhookToken: string | null;
  state: Record<string, unknown>;
};

/** a row of the global overview: a watch with its project */
export type WatchOverview = Pick<
  Watch,
  "id" | "name" | "kind" | "cron" | "at" | "enabled" | "disabledReason" | "runningSince" | "nextDueAt" | "lastRunAt" | "lastDurationMs" | "lastError" | "lastSentTo" | "runs" | "sends"
> & { projectId: string; projectName: string | null; projectSlug: string | null };

export type DryRun = { ok: boolean; result: string; log: string[]; sends: string[] };

export const watchFields = [
  "id",
  "name",
  "path",
  "layer",
  "kind",
  "cron",
  "at",
  "enabled",
  "disabledReason",
  "loadError",
  "nextDueAt",
  "runningSince",
  "lastRunAt",
  "lastDurationMs",
  "lastError",
  "lastOutput",
  "lastSentTo",
  "runs",
  "sends",
  "webhookToken",
  "state",
] as const;

export const watchKeys = {
  project: (projectId: string) => ["watches", projectId] as const,
  all: ["watches", "all"] as const,
};

export function useWatches(projectId: string | undefined) {
  return useQuery({
    queryKey: watchKeys.project(projectId ?? ""),
    enabled: !!projectId,
    queryFn: async () => unwrap(await listWatches({ fields: [...watchFields], input: { projectId: projectId! } })) as Watch[],
  });
}

/** every project's watches, the running ones first; refreshed while shown */
export function useAllWatches() {
  return useQuery({
    queryKey: watchKeys.all,
    refetchInterval: 10_000,
    queryFn: async () => unwrap(await listAllWatches({ fields: ["watches"] })).watches as WatchOverview[],
  });
}

/** what a watch's state means to a person */
export function watchState(w: Pick<Watch, "enabled" | "disabledReason" | "runningSince">): "running" | "on" | WatchDisabledReason {
  if (w.runningSince) return "running";
  if (!w.enabled) return w.disabledReason ?? "by_person";
  return "on";
}

export function useWatchActions(projectId: string | undefined) {
  const client = useQueryClient();
  const invalidate = () => {
    if (projectId) client.invalidateQueries({ queryKey: watchKeys.project(projectId) });
    client.invalidateQueries({ queryKey: watchKeys.all });
  };
  const toggle = useMutation({
    mutationFn: async ({ id, enabled }: { id: string; enabled: boolean }) =>
      unwrap(await switchWatch({ fields: [...watchFields], input: { id, enabled } })) as Watch,
    onSuccess: invalidate,
  });
  const dryRun = useMutation({
    mutationFn: async (id: string) => unwrap(await dryRunWatch({ fields: ["ok", "result", "log", "sends"], input: { id } })) as DryRun,
  });
  const remove = useMutation({
    mutationFn: async (id: string) => unwrap(await deleteWatch({ input: { id } })),
    onSuccess: invalidate,
  });
  return { toggle, dryRun, remove };
}
