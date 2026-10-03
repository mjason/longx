import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { computerSettings, computerConfigure, computerConnection, computerConnect, computerDisconnect, computerDevices, computerAliases, computerDelete, computerSetAlias, computerDeleteAlias, computerSetDefault } from "@/core/api";
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

export type ComputerDevice = ComputerSettings & { id: string; name: string; connection: ComputerConnection };
export type ComputerAliases = { default: string | null; aliases: { name: string; computers: string[] }[] };
const devicesKey = ["computer-devices"] as const;
const aliasesKey = ["computer-aliases"] as const;
export function useComputerDevices() {
  return useQuery({ queryKey: devicesKey, retry: false, refetchInterval: 2000,
    queryFn: async () => unwrap(await computerDevices()) as ComputerDevice[] });
}
export function useComputerAliases() {
  return useQuery({ queryKey: aliasesKey, retry: false,
    queryFn: async () => unwrap(await computerAliases()) as ComputerAliases });
}
export function useComputerDeviceActions() {
  const client = useQueryClient();
  const refresh = () => {
    void client.invalidateQueries({ queryKey: devicesKey });
    void client.invalidateQueries({ queryKey: aliasesKey });
    void client.invalidateQueries({ queryKey: settingsKey });
    void client.invalidateQueries({ queryKey: connectionKey });
  };
  return {
    save: useMutation({ mutationFn: async (input: { id: string; name: string; url: string; token: string }) => unwrap(await computerConfigure({ input })), onSuccess: refresh }),
    connect: useMutation({ mutationFn: async (input: { id: string; foreground: boolean }) => unwrap(await computerConnect({ input })), onSuccess: refresh }),
    disconnect: useMutation({ mutationFn: async (id: string) => unwrap(await computerDisconnect({ input: { id } })), onSuccess: refresh }),
    remove: useMutation({ mutationFn: async (id: string) => unwrap(await computerDelete({ input: { id } })), onSuccess: refresh }),
    alias: useMutation({ mutationFn: async (input: { name: string; computers: string[] }) => unwrap(await computerSetAlias({ input })), onSuccess: refresh }),
    deleteAlias: useMutation({ mutationFn: async (name: string) => unwrap(await computerDeleteAlias({ input: { name } })), onSuccess: refresh }),
    defaultAlias: useMutation({ mutationFn: async (name: string) => unwrap(await computerSetDefault({ input: { name } })), onSuccess: refresh }),
  };
}
