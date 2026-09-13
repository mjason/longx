// One file's diff — the working tree against HEAD, or what a commit did —
// drawn with the code-diff element the chat already uses for the agent's
// file changes.
import { parseDiff } from "@/ui/chat/toolkit";
import { CodeDiff } from "@/ui/components/assistant-ui/elements/code-diff";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { useGitCommitFileDiff, useGitFileDiff, type FileDiff } from "@/core/workspace";
import { t } from "@/ui/strings";

export function DiffTab({ projectId, path, sha }: { projectId: string; path: string; sha: string | null }) {
  const working = useGitFileDiff(projectId, sha === null ? path : null);
  const committed = useGitCommitFileDiff(projectId, sha, sha === null ? null : path);
  const query = sha === null ? working : committed;
  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="diff-tab">
      <div className="bg-sidebar border-sidebar-border flex h-9 shrink-0 items-center gap-2 border-b px-3 text-xs">
        <span className="text-muted-foreground min-w-0 flex-1 truncate font-mono">{path}</span>
        {sha ? <span className="font-mono">{sha.slice(0, 7)}</span> : null}
      </div>
      <div className="min-h-0 flex-1 overflow-auto p-3">
        {query.isPending ? <Skeleton className="h-24 w-full" /> : query.isError ? <p className="text-destructive text-sm">{query.error.message}</p> : <DiffBody path={path} diff={query.data} />}
      </div>
    </div>
  );
}

function DiffBody({ path, diff }: { path: string; diff: FileDiff }) {
  if (diff.binary) return <p className="text-muted-foreground text-sm">{t.binaryDiff}</p>;
  if (!diff.diff.trim()) return <p className="text-muted-foreground text-sm">{t.noDiff}</p>;
  const parsed = parseDiff(diff.diff);
  return <CodeDiff filename={path} lines={parsed.lines} additions={parsed.additions} deletions={parsed.deletions} className="max-w-none" />;
}
