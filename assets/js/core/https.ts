// HTTPS for Longx itself (Longx.Tls): the status the settings page reads —
// polled every second while a certificate is being obtained —, lego's DNS
// providers, and saving / issuing / turning off. The provider's variables go
// out as name–value pairs and never come back: the status only names the
// ones that have a value.
import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { setTls, tlsDisable, tlsIssue, tlsProviders, tlsResolution, tlsStatus } from "@/core/api";
import type { SetTlsInput, TlsProvidersQuery, TlsResolutionQuery, TlsStatusQuery } from "@/gql/graphql";
import { unwrap } from "./projects";
import i18n from "./i18n";

export type TlsStatus = TlsStatusQuery["tlsStatus"];
export type TlsProvider = TlsProvidersQuery["tlsProviders"]["providers"][number];
export type TlsResolutionReport = TlsResolutionQuery["tlsResolution"];
export type TlsStage = "idle" | "downloading" | "verifying" | "extracting" | "issuing" | "failed";

export const tlsKeys = {
  status: ["tls", "status"] as const,
  providers: ["tls", "providers"] as const,
  resolution: (domains: string[]) => ["tls", "resolution", domains.join(",")] as const,
};

/** the stages during which the server is working and the page keeps asking */
export const tlsBusy = (stage: string | undefined): boolean =>
  stage === "downloading" || stage === "verifying" || stage === "extracting" || stage === "issuing";

export function useTlsStatus() {
  return useQuery({
    queryKey: tlsKeys.status,
    queryFn: async () => unwrap(await tlsStatus()) as TlsStatus,
    refetchInterval: (query) => (tlsBusy(query.state.data?.stage) ? 1000 : false),
  });
}

export function useTlsProviders() {
  return useQuery({
    queryKey: tlsKeys.providers,
    staleTime: Infinity,
    queryFn: async () => (unwrap(await tlsProviders()) as TlsProvidersQuery["tlsProviders"]).providers,
  });
}

/**
 * Where the names point as the world sees them (the public resolvers — a
 * proxy's fake-ip DNS on the server does not hide the A record), this
 * machine's answer beside it, and the resolvers the TXT check would use.
 * The names as typed, once typing pauses.
 */
export function useTlsResolution(domains: string[]) {
  const settled = useDebounced(domains.join(","), 600);
  const names = settled ? settled.split(",") : [];
  return useQuery({
    queryKey: tlsKeys.resolution(names),
    enabled: names.length > 0,
    staleTime: 30_000,
    queryFn: async () => unwrap(await tlsResolution({ input: { domains: names } })) as TlsResolutionReport,
  });
}

/** `value`, once it has not changed for `ms` */
export function useDebounced<T>(value: T, ms: number): T {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), ms);
    return () => clearTimeout(timer);
  }, [value, ms]);
  return settled;
}

/** "1.1.1.1, 8.8.8.8:53" → the entries (the server checks and normalises them) */
export function parseResolvers(text: string): string[] {
  return text
    .split(/[\s,，]+/)
    .map((r) => r.trim())
    .filter(Boolean);
}

/** what a proxy's config needs so this name gets its real address and goes direct */
export function proxySnippet(domain: string): string {
  return `dns:\n  fake-ip-filter:\n    - "+.${domain}"\nrules:\n  - DOMAIN-SUFFIX,${domain},DIRECT`;
}

function useTlsMutation<T>(fn: (input: T) => Promise<TlsStatus>) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (status) => client.setQueryData(tlsKeys.status, status),
  });
}

export function useSaveTls() {
  return useTlsMutation(async (input: SetTlsInput) => unwrap(await setTls({ input })) as TlsStatus);
}

export function useIssueTls() {
  return useTlsMutation(async (_: void) => unwrap(await tlsIssue()) as TlsStatus);
}

export function useDisableTls() {
  return useTlsMutation(async (_: void) => unwrap(await tlsDisable()) as TlsStatus);
}

/**
 * The variables to send: what was typed (a value), a stored one the person
 * cleared (null); a field left empty keeps what is stored and is not sent.
 */
export function envInput(typed: Record<string, string>, cleared: string[]): { name: string; value: string | null }[] {
  const out: { name: string; value: string | null }[] = [];
  for (const [name, value] of Object.entries(typed)) {
    if (value.trim() !== "") out.push({ name, value: value.trim() });
  }
  for (const name of cleared) if (!(name in typed) || typed[name]!.trim() === "") out.push({ name, value: null });
  return out;
}

/** "lx.example.com, *.lx.example.com" or one per line → the names */
export function parseDomains(text: string): string[] {
  return text
    .split(/[\s,，]+/)
    .map((d) => d.trim())
    .filter(Boolean);
}

/** the providers people here mostly use, first and by their Chinese names */
export const FEATURED_PROVIDERS = ["tencentcloud", "alidns", "huaweicloud", "cloudflare", "dnsupdate", "exec"].map((code) => ({
  code,
  get label() { return i18n.t(`core.dnsProviders.${code}`); },
}));

export function providerLabel(provider: Pick<TlsProvider, "code" | "name"> | undefined | null): string {
  if (!provider) return "";
  return FEATURED_PROVIDERS.find((f) => f.code === provider.code)?.label ?? provider.name;
}

/** days until the certificate runs out (negative once it has), null without one */
export function daysLeft(notAfter: string | null | undefined, now: Date = new Date()): number | null {
  if (!notAfter) return null;
  return Math.floor((new Date(notAfter).getTime() - now.getTime()) / 86_400_000);
}
