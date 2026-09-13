// One file's diff — the working tree against HEAD, or what a commit did —
// as GitHub's file view: both versions in CodeMirror's merge view, split on
// a desktop, inline on a phone, either on request.
import { useState } from "react";
import { useViewport } from "@/core/viewport";
import { useGitFileVersions, type FileVersions } from "@/core/workspace";
import { DiffView } from "@/ui/editor/DiffView";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Tabs, TabsList, TabsTrigger } from "@/ui/components/ui/tabs";
import { t } from "@/ui/strings";

export function DiffTab({ projectId, path, sha }: { projectId: string; path: string; sha: string | null }) {
  const viewport = useViewport();
  const query = useGitFileVersions(projectId, sha, path);
  const [mode, setMode] = useState<"split" | "unified" | null>(null);
  const effective = mode ?? (viewport === "phone" ? "unified" : "split");
  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="diff-tab">
      <div className="bg-sidebar border-sidebar-border flex h-9 shrink-0 items-center gap-2 border-b px-3 text-xs">
        <span className="text-muted-foreground min-w-0 flex-1 truncate font-mono">{path}</span>
        {sha ? <span className="font-mono">{sha.slice(0, 7)}</span> : null}
        <Tabs value={effective} onValueChange={(v) => setMode(v as "split" | "unified")}>
          <TabsList className="h-7">
            <TabsTrigger value="split" className="h-6 px-2 text-xs">
              {t.diffSplit}
            </TabsTrigger>
            <TabsTrigger value="unified" className="h-6 px-2 text-xs">
              {t.diffUnified}
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        {query.isPending ? (
          <Skeleton className="m-3 h-24" />
        ) : query.isError ? (
          <p className="text-destructive p-3 text-sm">{query.error.message}</p>
        ) : (
          <DiffBody path={path} versions={query.data} mode={effective} wrap={viewport === "phone"} />
        )}
      </div>
    </div>
  );
}

function DiffBody({ path, versions, mode, wrap }: { path: string; versions: FileVersions; mode: "split" | "unified"; wrap: boolean }) {
  if (versions.binary) return <p className="text-muted-foreground p-3 text-sm">{t.binaryDiff}</p>;
  if (versions.before === versions.after) return <p className="text-muted-foreground p-3 text-sm">{t.noDiff}</p>;
  return <DiffView path={path} before={versions.before} after={versions.after} mode={mode} wrap={wrap} />;
}
