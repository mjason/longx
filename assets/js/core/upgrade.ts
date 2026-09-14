// The version and its upgrade (Longx.Upgrade over RPC): the status the
// settings page and the status strip read, the check / apply / token
// mutations, and the reload once the new version answers.
import {
  useMutation,
  useQuery,
  useQueryClient,
  type QueryClient,
} from "@tanstack/react-query";
import { useEffect, useRef } from "react";
import {
  setGithubToken,
  upgradeApply,
  upgradeCheck,
  upgradeStatus,
} from "@/ash_rpc";
import { unwrap } from "./projects";

export type UpgradeStage =
  | "idle"
  | "downloading"
  | "verifying"
  | "installing"
  | "restarting"
  | "installed"
  | "failed";

export type UpgradeStatus = {
  current: string;
  installed: boolean;
  latest: string | null;
  available: boolean;
  notesUrl: string | null;
  checkedAt: string | null;
  error: string | null;
  stage: UpgradeStage;
  message: string | null;
  target: string | null;
  hasGithubToken: boolean;
};

export const upgradeFields = [
  "current",
  "installed",
  "latest",
  "available",
  "notesUrl",
  "checkedAt",
  "error",
  "stage",
  "message",
  "target",
  "hasGithubToken",
] as const;

export const upgradeKey = ["upgrade"] as const;

/** the stages during which the server is busy and the page keeps asking */
export const inProgress = (stage: UpgradeStage) =>
  stage === "downloading" ||
  stage === "verifying" ||
  stage === "installing" ||
  stage === "restarting";

/** the one browser call here, so a test can stand in for it */
export const page = { reload: () => window.location.reload() };

/**
 * The status, polled every second while an upgrade runs (through the
 * restart, when the server is away for a moment). The first version seen
 * is remembered: a status from another version means the new one is up —
 * the page reloads to load its assets.
 */
export function useUpgradeStatus(opts: { poll?: boolean } = {}) {
  const query = useQuery({
    queryKey: upgradeKey,
    queryFn: async () =>
      unwrap(await upgradeStatus({ fields: [...upgradeFields] })) as UpgradeStatus,
    retry: false,
    staleTime: 60_000,
    refetchInterval: (q) => {
      const st = q.state.data;
      if (opts.poll === false) return false;
      return st && inProgress(st.stage) ? 1000 : false;
    },
  });
  const first = useRef<string | null>(null);
  const current = query.data?.current ?? null;
  useEffect(() => {
    if (current === null) return;
    if (first.current === null) first.current = current;
    else if (first.current !== current) page.reload();
  }, [current]);
  return query;
}

function put(client: QueryClient, status: UpgradeStatus) {
  client.setQueryData(upgradeKey, status);
}

export function useUpgradeActions() {
  const client = useQueryClient();
  return {
    check: useMutation({
      mutationFn: async () =>
        unwrap(await upgradeCheck({ fields: [...upgradeFields] })) as UpgradeStatus,
      onSuccess: (status) => put(client, status),
    }),
    apply: useMutation({
      mutationFn: async () =>
        unwrap(await upgradeApply({ fields: [...upgradeFields] })) as UpgradeStatus,
      onSuccess: (status) => put(client, status),
    }),
    setToken: useMutation({
      mutationFn: async (token: string | null) =>
        unwrap(
          await setGithubToken({ fields: [...upgradeFields], input: { token } }),
        ) as UpgradeStatus,
      onSuccess: (status) => put(client, status),
    }),
  };
}
