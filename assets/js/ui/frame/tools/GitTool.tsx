import { useGitInfo } from "@/core/projects";
import { GitCard } from "@/ui/pages/project/GitCard";
import type { ProjectContext } from "../ProjectWindow";

/** Git tool window: state now; per-turn bookmarks and restore come with the history branch. */
export function GitTool({ ctx }: { ctx: ProjectContext }) {
  const git = useGitInfo(ctx.id);
  return (
    <div data-testid="git-tool">
      <GitCard git={git.data} loading={git.isPending} projectId={ctx.id} />
    </div>
  );
}
