// The command-line tools the agent's shell work leans on: what the server
// found on its PATH, what is missing, and the install line for its platform.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { checkDependencies, dependencies } from "@/ash_rpc";
import { unwrap } from "@/core/projects";

export type DependencyTool = {
  name: string;
  command: string;
  found: boolean;
  path: string | null;
  version: string | null;
  install: { apt: string; brew: string; winget: string | null };
};

export type DependencyReport = {
  os: string;
  missing: number;
  installCommand: string | null;
  tools: DependencyTool[];
  checkedAt: string;
};

const fields = ["os", "missing", "installCommand", "tools", "checkedAt"] as const;
export const dependencyKeys = { report: ["dependencies"] as const };

export function useDependencies() {
  return useQuery({
    queryKey: dependencyKeys.report,
    queryFn: async () => unwrap(await dependencies({ fields: [...fields] })) as DependencyReport,
    staleTime: 60_000,
  });
}

export function useCheckDependencies() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async () => unwrap(await checkDependencies({ fields: [...fields] })) as DependencyReport,
    onSuccess: (report) => client.setQueryData(dependencyKeys.report, report),
  });
}
