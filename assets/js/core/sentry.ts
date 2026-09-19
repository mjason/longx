// Error reporting (Longx.Sentry): on once a DSN is saved in the settings,
// off when it is cleared; a test event to prove the wiring. DOM-free.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { sentryStatus, sentryTest, setSentryDsn } from "@/ash_rpc";
import { unwrap } from "@/core/projects";

export type SentryStatus = { enabled: boolean; dsn: string | null; environment: string; release: string };

const fields = ["enabled", "dsn", "environment", "release"] as const;
export const sentryKey = ["sentry"] as const;

export function useSentryStatus() {
  return useQuery({
    queryKey: sentryKey,
    queryFn: async () => unwrap(await sentryStatus({ fields: [...fields] })) as SentryStatus,
  });
}

export function useSentryActions() {
  const client = useQueryClient();
  const setDsn = useMutation({
    mutationFn: async (dsn: string) => unwrap(await setSentryDsn({ fields: [...fields], input: { dsn } })) as SentryStatus,
    onSuccess: (status) => client.setQueryData(sentryKey, status),
  });
  const test = useMutation({
    mutationFn: async () => unwrap(await sentryTest({ fields: ["ok", "message"] })) as { ok: boolean; message: string },
  });
  return { setDsn, test };
}
