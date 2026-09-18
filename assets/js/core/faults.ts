// The server's recent faults (Longx.System.Faults): what the serializer
// could not encode, what the wire cleaner had to scrub — the settings page
// lists them, the status strip counts the last hour's. DOM-free.
import { useQuery } from "@tanstack/react-query";
import { recentFaults } from "@/ash_rpc";
import { unwrap } from "@/core/projects";

export type Fault = { kind: string; where: string | null; detail: string; at: string };
export type FaultReport = { faults: Fault[]; recent: number };

export const faultKeys = { recent: ["faults"] as const };

export function useFaults(options: { refetchInterval?: number | false } = {}) {
  return useQuery({
    queryKey: faultKeys.recent,
    queryFn: async () => unwrap(await recentFaults({ fields: ["faults", "recent"] })) as FaultReport,
    refetchInterval: options.refetchInterval ?? 60_000,
    staleTime: 10_000,
  });
}
