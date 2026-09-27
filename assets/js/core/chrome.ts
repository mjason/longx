// The person's browsers reached through the Longx Chrome extension
// (Longx.Chrome): the paired extensions with their live state, the
// approvals, names and limits, the aliases descriptions name, and
// where the extension is downloaded from.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  approveChromeBrowser,
  chromeAliases,
  chromeExtension,
  deleteChromeAlias,
  listChromeBrowsers,
  rejectChromeBrowser,
  renameChromeBrowser,
  revokeChromeBrowser,
  setChromeAlias,
  setChromeBrowserMaxTabs,
  setChromeDefaultAlias,
} from "@/core/api";
import { unwrap } from "./projects";

export type ChromeBrowser = {
  id: string;
  name: string;
  device: { name?: string; platform?: string; ua?: string; extension?: string };
  status: "pending" | "approved" | "revoked";
  connected: boolean;
  maxTabs: number;
  lastSeenAt: string | null;
  approvedAt: string | null;
  tabs: { threadId: string; title: string; tabs: number }[];
  aliases: string[];
};

export type ChromeAliases = { aliases: { name: string; browsers: string[] }[]; default: string | null };

export type ChromeExtension = { url: string; version: string | null; built: boolean; minimumChrome: string };

export const chromeKeys = {
  browsers: ["chrome", "browsers"] as const,
  aliases: ["chrome", "aliases"] as const,
  extension: ["chrome", "extension"] as const,
};

const aliasFields = ["aliases", "default"] as const;

/** every paired extension; refreshed often while shown — a pairing request is answered here */
export function useChromeBrowsers(options: { refetchInterval?: number | false } = {}) {
  return useQuery({
    queryKey: chromeKeys.browsers,
    refetchInterval: options.refetchInterval ?? 3000,
    queryFn: async () => (unwrap(await listChromeBrowsers()) as { browsers: ChromeBrowser[] }).browsers,
  });
}

export function useChromeAliases() {
  return useQuery({
    queryKey: chromeKeys.aliases,
    queryFn: async () => unwrap(await chromeAliases()) as ChromeAliases,
  });
}

export function useChromeExtension() {
  return useQuery({
    queryKey: chromeKeys.extension,
    staleTime: 60_000,
    queryFn: async () => unwrap(await chromeExtension()) as ChromeExtension,
  });
}

function useBrowsersMutation<T>(fn: (input: T) => Promise<unknown>) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSettled: () => {
      void client.invalidateQueries({ queryKey: chromeKeys.browsers });
      void client.invalidateQueries({ queryKey: chromeKeys.aliases });
    },
  });
}

export function useApproveBrowser() {
  return useBrowsersMutation(async (id: string) => unwrap(await approveChromeBrowser({ input: { id } })));
}

export function useRejectBrowser() {
  return useBrowsersMutation(async (id: string) => unwrap(await rejectChromeBrowser({ input: { id } })));
}

export function useRevokeBrowser() {
  return useBrowsersMutation(async (id: string) => unwrap(await revokeChromeBrowser({ input: { id } })));
}

export function useRenameBrowser() {
  return useBrowsersMutation(async (input: { id: string; name: string }) => unwrap(await renameChromeBrowser({ input })));
}

export function useSetBrowserMaxTabs() {
  return useBrowsersMutation(async (input: { id: string; maxTabs: number }) => unwrap(await setChromeBrowserMaxTabs({ input })));
}

function useAliasesMutation<T>(fn: (input: T) => Promise<ChromeAliases>) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (data) => {
      client.setQueryData(chromeKeys.aliases, data);
      void client.invalidateQueries({ queryKey: chromeKeys.browsers });
    },
  });
}

export function useSetChromeAlias() {
  return useAliasesMutation(
    async (input: { name: string; browsers: string[] }) => unwrap(await setChromeAlias({ input })) as ChromeAliases,
  );
}

export function useDeleteChromeAlias() {
  return useAliasesMutation(async (name: string) => unwrap(await deleteChromeAlias({ input: { name } })) as ChromeAliases);
}

export function useSetChromeDefaultAlias() {
  return useAliasesMutation(
    async (name: string | null) => unwrap(await setChromeDefaultAlias({ input: { name } })) as ChromeAliases,
  );
}
