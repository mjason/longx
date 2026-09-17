import { AlertTriangle, ArrowUpCircle, Download, GitBranch } from "lucide-react";
import { Link } from "react-router";
import { browserBusy, browserPercent, useBrowserStatus } from "@/core/browser";
import { shortSha } from "@/core/format";
import { useDependencies } from "@/core/dependencies";
import { useGitInfo } from "@/core/projects";
import { useUpgradeStatus } from "@/core/upgrade";
import { t } from "@/ui/strings";
import type { ProjectContext } from "./ProjectWindow";

const item = (extra = "") => `flex shrink-0 items-center gap-1 whitespace-nowrap ${extra}`;

/** IDEA's status bar: HEAD, an update waiting. One thin line. */
export function StatusStrip({ ctx }: { ctx: ProjectContext }) {
  const git = useGitInfo(ctx.id);
  const upgrade = useUpgradeStatus({ poll: false });
  const deps = useDependencies();
  const browser = useBrowserStatus();

  return (
    // every item stays on one line: a narrow phone scrolls the strip sideways
    <div className="bg-sidebar border-sidebar-border text-muted-foreground flex h-7 items-center gap-4 overflow-x-auto border-t px-3 text-xs" data-testid="status-strip">
      <span className={item("font-mono")} title="HEAD">
        <GitBranch className="size-3" /> {git.data ? (git.data.repository ? shortSha(git.data.head) : "no git") : "…"}
        {git.data?.repository && !git.data.clean ? <span className="text-warning">·{git.data.changes}</span> : null}
      </span>
      {deps.data && deps.data.missing > 0 ? (
        <Link to="/settings/dependencies" className={item("text-warning hover:underline")} title={t.dependenciesPage.hint}>
          <AlertTriangle className="size-3" /> {t.dependenciesPage.missing(deps.data.missing)}
        </Link>
      ) : null}
      {browser.data && browserBusy(browser.data.stage) ? (
        <Link to="/settings/agent" className={item("text-warning hover:underline")} title={t.agentKernel.browserTitle}>
          <Download className="size-3" /> {t.agentKernel.browserStrip(browserPercent(browser.data))}
        </Link>
      ) : null}
      {upgrade.data?.available && upgrade.data.latest ? (
        <Link to="/settings/update" className={item("text-primary hover:underline")} title={t.updatePage.hint}>
          <ArrowUpCircle className="size-3" /> {t.updatePage.newVersion(upgrade.data.latest)}
        </Link>
      ) : null}
    </div>
  );
}
