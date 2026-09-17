// The headless browser's download (Longx.Browser.Installer over RPC): the
// status the kernel settings card and the status strip read, polled every
// second while a stage runs, and the install / retry mutation.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { browserInstall, browserStatus } from "@/ash_rpc";
import { unwrap } from "./projects";

export type BrowserStage = "idle" | "downloading" | "verifying" | "extracting" | "installed" | "failed";

export type BrowserStatus = {
  stage: BrowserStage;
  /** bytes of the archive so far (total null without a content-length) */
  received: number;
  total: number | null;
  error: string | null;
  version: string;
  /** the version Longx pins (what a download installs) */
  latest: string;
  /** null where upstream builds nothing for this platform */
  target: string | null;
  /** the binary in use, when there is one */
  path: string | null;
  /** where it comes from: LONGX_OBSCURA, the machine's PATH, or the download; null when none */
  source: BrowserSource | null;
  /** the version of the binary in use (a download's directory, or what --version prints) */
  installedVersion: string | null;
  /** a download older than the pin: install/0 replaces it */
  upgradable: boolean;
};

export type BrowserSource = "env" | "system" | "downloaded";

export const browserFields = [
  "stage",
  "received",
  "total",
  "error",
  "version",
  "latest",
  "target",
  "path",
  "source",
  "installedVersion",
  "upgradable",
] as const;

export const browserKey = ["browser-status"] as const;

/** the stages during which the server is busy and the page keeps asking */
export const browserBusy = (stage: BrowserStage) =>
  stage === "downloading" || stage === "verifying" || stage === "extracting";

/** whole percent of the download, null until the total is known */
export function browserPercent(st: Pick<BrowserStatus, "received" | "total">): number | null {
  if (!st.total || st.total <= 0) return null;
  return Math.min(100, Math.floor((st.received / st.total) * 100));
}

export function useBrowserStatus(opts: { poll?: boolean } = {}) {
  return useQuery({
    queryKey: browserKey,
    queryFn: async () => unwrap(await browserStatus({ fields: [...browserFields] })) as BrowserStatus,
    retry: false,
    staleTime: 10_000,
    refetchInterval: (q) => {
      if (opts.poll === false) return false;
      const st = q.state.data;
      return st && browserBusy(st.stage) ? 1000 : false;
    },
  });
}

export function useBrowserInstall() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async () => unwrap(await browserInstall({ fields: [...browserFields] })) as BrowserStatus,
    onSuccess: (status) => client.setQueryData(browserKey, status),
  });
}
