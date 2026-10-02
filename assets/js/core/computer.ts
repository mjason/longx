// The local CUA Driver download, not a desktop connection or permission grant.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { computerInstall, computerStatus } from "@/core/api";
import type { BrowserStatus } from "./browser";
import { browserBusy } from "./browser";
import { unwrap } from "./projects";

export type ComputerStatus = BrowserStatus & {
  appPath: string | null;
  downloadSize: number | null;
};

export const computerKey = ["computer-status"] as const;

export function useComputerStatus() {
  return useQuery({
    queryKey: computerKey,
    queryFn: async () => unwrap(await computerStatus()) as ComputerStatus,
    retry: false,
    staleTime: 10_000,
    refetchInterval: (q) => q.state.data && browserBusy(q.state.data.stage) ? 1000 : false,
  });
}

export function useComputerInstall() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async () => unwrap(await computerInstall()) as ComputerStatus,
    onSuccess: (status) => client.setQueryData(computerKey, status),
  });
}
