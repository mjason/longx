// The agents' live commands (Longx.System.Commands): what runs right now,
// for which session, and a way to end one from the settings page.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { killCommand, runningCommands } from "@/ash_rpc";
import { unwrap } from "./projects";

export type CommandSession = {
  title: string;
  slug: string;
  threadRowId: string;
  rootRowId: string;
  agent: string | null;
};

export type RunningCommand = {
  id: string;
  cmd: string;
  osPid: number | null;
  threadId: string | null;
  startedAt: number | null;
  elapsedMs: number | null;
  session: CommandSession | null;
};

export function useRunningCommands(options: { refetchInterval?: number | false } = {}) {
  return useQuery({
    queryKey: ["commands", "running"],
    refetchInterval: options.refetchInterval ?? 2000,
    queryFn: async () => (unwrap(await runningCommands({ fields: ["commands"] })) as { commands: RunningCommand[] }).commands,
  });
}

export function useKillCommand() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => unwrap(await killCommand({ fields: ["ok"], input: { id } })),
    onSettled: () => client.invalidateQueries({ queryKey: ["commands", "running"] }),
  });
}
