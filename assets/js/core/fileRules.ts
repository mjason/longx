// What Longx ignores in a project (Longx.Projects.FileRules): the global rules
// and a project's own, gitignore syntax, stacked on the built-in lists —
// DOM-free hooks. Saving reloads every open project's file watcher; the
// tree's ignored list is refetched with it.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { fileRules, setFileRules, updateProject } from "@/ash_rpc";
import { queryKeys, unwrap } from "./projects";

/** two texts, gitignore syntax: `ignore` hides, `watch` keeps watched what .gitignore hides */
export type FileRules = { ignore: string; watch: string };
export type GlobalFileRules = FileRules & { builtinIgnore: string[]; builtinWatch: string[] };

const fields = ["ignore", "watch", "builtinIgnore", "builtinWatch"] as const;
const key = ["file-rules"] as const;

export function useFileRules() {
  return useQuery({ queryKey: key, queryFn: async () => unwrap(await fileRules({ fields: [...fields] })) as GlobalFileRules });
}

export function useSaveFileRules() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: FileRules) => unwrap(await setFileRules({ fields: [...fields], input })) as GlobalFileRules,
    onSuccess: (data) => {
      client.setQueryData(key, data);
      void client.invalidateQueries({ queryKey: ["files"] });
    },
  });
}

/** a project's own rules (`Project.file_rules`), saved on their own */
export function useSaveProjectFileRules(projectId: string, slug: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (rules: FileRules) => unwrap(await updateProject({ identity: projectId, fields: ["id"], input: { fileRules: rules } })),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: queryKeys.project(slug) });
      void client.invalidateQueries({ queryKey: ["files", projectId] });
    },
  });
}

/** the texts a project row carries (a map with string keys; absent = "") */
export function projectFileRules(value: unknown): FileRules {
  const map = (value ?? {}) as Record<string, unknown>;
  return { ignore: typeof map.ignore === "string" ? map.ignore : "", watch: typeof map.watch === "string" ? map.watch : "" };
}
