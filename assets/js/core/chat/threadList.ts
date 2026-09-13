// The project's threads as assistant-ui's ExternalStoreThreadListAdapter:
// rows come from the RPC (TanStack), the current one from the route, and
// each handler that exists turns its menu item on in the ThreadList element.
import type { ExternalStoreThreadData, ExternalStoreThreadListAdapter } from "@assistant-ui/react";

export type ThreadRow = {
  id: string;
  codexThreadId: string;
  title: string | null;
  preview: string | null;
  status: string;
  modelSlug?: string | null;
  sandbox?: string;
  approvalPolicy?: string;
  networkAccess?: boolean;
  webSearch?: boolean;
};

export type ThreadListActions = {
  switchTo?: (threadId: string) => void;
  create?: () => Promise<void>;
  rename?: (threadId: string, title: string) => Promise<void>;
  archive?: (threadId: string) => Promise<void>;
  delete?: (threadId: string) => Promise<void>;
};

export function buildThreadListAdapter(opts: { rows: readonly ThreadRow[]; currentId: string | undefined; actions: ThreadListActions; loading?: boolean }): ExternalStoreThreadListAdapter {
  const { rows, actions } = opts;
  const data = <S extends "regular" | "archived">(row: ThreadRow, status: S): ExternalStoreThreadData<S> => ({
    status,
    id: row.id,
    title: row.title ?? row.preview ?? undefined,
  });
  return {
    threadId: opts.currentId,
    ...(opts.loading !== undefined ? { isLoading: opts.loading } : {}),
    threads: rows.filter((r) => r.status !== "archived").map((r) => data(r, "regular")),
    archivedThreads: rows.filter((r) => r.status === "archived").map((r) => data(r, "archived")),
    ...(actions.switchTo ? { onSwitchToThread: actions.switchTo } : {}),
    ...(actions.create ? { onSwitchToNewThread: actions.create } : {}),
    ...(actions.rename ? { onRename: actions.rename } : {}),
    ...(actions.archive ? { onArchive: actions.archive } : {}),
    ...(actions.delete ? { onDelete: actions.delete } : {}),
  };
}
