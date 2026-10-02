import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { computerSettings, computerConfigure, computerConnection, computerConnect, computerDisconnect } from "@/core/api";
import { unwrap } from "./projects";

export type ComputerSettings = { url: string; hasToken: boolean };
export type ComputerConnection = {
  phase: "disconnected" | "connecting" | "ready";
  foreground: boolean;
  busy: boolean;
  toolCount: number;
  permissions: string | null;
  error: string | null;
};
const settingsKey = ["computer-settings"] as const;
const connectionKey = ["computer-connection"] as const;
export function useComputerSettings() {
  return useQuery({ queryKey: settingsKey, retry: false,
    queryFn: async () => unwrap(await computerSettings()) as ComputerSettings });
}
export function useComputerConfigure() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: { url: string; token: string }) => unwrap(await computerConfigure({ input })) as ComputerSettings,
    onSuccess: (settings) => {
      client.setQueryData(settingsKey, settings);
      void client.invalidateQueries({ queryKey: connectionKey });
    },
  });
}
export function useComputerConnection() {
  return useQuery({ queryKey: connectionKey, retry: false, refetchInterval: 2000,
    queryFn: async () => unwrap(await computerConnection()) as ComputerConnection });
}
export function useComputerConnectionActions() {
  const client = useQueryClient();
  const update = (data: ComputerConnection) => client.setQueryData(connectionKey, data);
  const connect = useMutation({
    mutationFn: async (foreground: boolean) => unwrap(await computerConnect({ input: { foreground } })) as ComputerConnection,
    onSuccess: update,
  });
  const disconnect = useMutation({
    mutationFn: async () => unwrap(await computerDisconnect()) as ComputerConnection,
    onSuccess: update,
  });
  return { connect, disconnect };
}
