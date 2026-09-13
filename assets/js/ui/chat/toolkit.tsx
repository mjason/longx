// How codex's items render inside an assistant message. The toolkit maps
// tool names (see core/chat/messages.ts) to renderers built from the
// assistant-ui elements we own (elements/terminal-block, code-diff,
// web-search, approval-card); dynamic tools (`ns.name`) fall through to the
// ToolFallback element. Approvals are answered through assistant-ui's
// `respondToApproval` seam (option id = our decision).
import { AuiConfig, defineToolkit, Tools, type ToolCallMessagePartComponent, type ToolCallMessagePartProps } from "@assistant-ui/react";
import { FileDiffIcon } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { ApprovalCard, type ApprovalLabels } from "@/ui/components/assistant-ui/elements/approval-card";
import { CodeDiff, type DiffLine } from "@/ui/components/assistant-ui/elements/code-diff";
import { TerminalBlock } from "@/ui/components/assistant-ui/elements/terminal-block";
import { WebSearch } from "@/ui/components/assistant-ui/elements/web-search";
import { t } from "@/ui/strings";

type CommandArgs = { command?: string; fullCommand?: string; cwd?: string };
type CommandResult = { status: string; exitCode: number | null; output: string; durationMs?: number | null };

type FileChange = { path: string; kind?: { type?: string; move_path?: string | null }; diff?: string };
type FileChangeArgs = { changes?: FileChange[] };
type FileChangeResult = { status: string; output: string };

type WebSearchArgs = { query?: string };
type WebSearchResult = { results?: { title?: string; url?: string }[] | null };

const APPROVAL_LABELS: ApprovalLabels = { allowOnce: t.allowOnce, alwaysAllow: t.allowSession, deny: t.deny };

type ApprovalSeam = Pick<ToolCallMessagePartProps, "approval" | "respondToApproval">;

function pendingApproval(p: ApprovalSeam) {
  return p.approval && p.approval.approved === undefined && p.approval.resolution === undefined ? p.approval : undefined;
}

/** The three codex answers as assistant-ui option ids; disabled once one is sent. */
function useApprovalActions(p: ApprovalSeam) {
  const [sent, setSent] = useState(false);
  const answer = (optionId: string) => {
    if (sent) return;
    setSent(true);
    void p.respondToApproval({ optionId }).catch((error: unknown) => {
      setSent(false);
      toast.error(error instanceof Error ? error.message : String(error));
    });
  };
  return {
    disabled: sent,
    onAllowOnce: () => answer("accept"),
    onAlwaysAllow: () => answer("accept_for_session"),
    onDeny: () => answer("decline"),
  };
}

export const CommandExecutionTool: ToolCallMessagePartComponent<CommandArgs, CommandResult> = (p) => {
  const actions = useApprovalActions(p);
  const approval = pendingApproval(p);
  const command = p.args.command ?? "";
  const output = p.result?.output ?? (typeof p.artifact === "string" ? p.artifact : "");
  const lines = output ? output.replace(/\n$/, "").split("\n") : [];
  const done = p.result !== undefined || p.status.type !== "running";

  return (
    <div className="flex flex-col gap-2 py-1" data-testid="tool-command">
      {approval ? (
        <ApprovalCard state="request" title={t.approvalNeeded} subtitle={approval.prompt ?? t.approveCommand} command={p.args.fullCommand ?? command} labels={APPROVAL_LABELS} {...actions} />
      ) : null}
      <TerminalBlock
        command={command}
        fullCommand={p.args.fullCommand}
        lines={lines}
        done={done}
        exitCode={p.result?.exitCode ?? (done ? null : 0)}
        exitLabel={exitLabel(p)}
      />
    </div>
  );
};

function exitLabel(p: ToolCallMessagePartProps<CommandArgs, CommandResult>): string | undefined {
  if (p.result?.status === "declined") return t.declined;
  if (p.status.type === "incomplete") return t.cancelledTool;
  if (typeof p.result?.exitCode === "number") return t.exitCode(p.result.exitCode);
  return undefined;
}

export const FileChangeTool: ToolCallMessagePartComponent<FileChangeArgs, FileChangeResult> = (p) => {
  const actions = useApprovalActions(p);
  const approval = pendingApproval(p);
  const changes = p.args.changes ?? [];

  return (
    <div className="flex flex-col gap-2 py-1" data-testid="tool-file-change">
      {approval ? (
        <ApprovalCard
          state="request"
          icon={<FileDiffIcon className="size-4" />}
          title={t.approvalNeeded}
          subtitle={approval.prompt ?? t.approveFileChange}
          command={
            <ul>
              {changes.map((c) => (
                <li key={c.path}>{changeLabel(c)}</li>
              ))}
            </ul>
          }
          labels={APPROVAL_LABELS}
          {...actions}
        />
      ) : null}
      <p className="text-muted-foreground text-xs">
        {t.fileChanges(changes.length)}
        {p.result?.status === "declined" ? ` · ${t.declined}` : ""}
      </p>
      {changes.map((c) => {
        const parsed = parseDiff(c.diff ?? "");
        return <CodeDiff key={c.path} filename={changeLabel(c)} lines={parsed.lines} additions={parsed.additions} deletions={parsed.deletions} />;
      })}
    </div>
  );
};

function changeLabel(c: FileChange): string {
  const kind = c.kind?.type;
  if (kind === "add") return `+ ${c.path}`;
  if (kind === "delete") return `− ${c.path}`;
  if (c.kind?.move_path) return `${c.path} → ${c.kind.move_path}`;
  return c.path;
}

/** A unified diff (as codex sends per file) → lines the CodeDiff element draws. */
export function parseDiff(diff: string): { lines: DiffLine[]; additions: number; deletions: number } {
  const lines: DiffLine[] = [];
  let additions = 0;
  let deletions = 0;
  for (const raw of diff.replace(/\n$/, "").split("\n")) {
    if (raw.startsWith("+++") || raw.startsWith("---") || raw.startsWith("diff ") || raw.startsWith("index ")) continue;
    if (raw.startsWith("+")) {
      additions++;
      lines.push({ kind: "added", text: raw.slice(1) });
    } else if (raw.startsWith("-")) {
      deletions++;
      lines.push({ kind: "removed", text: raw.slice(1) });
    } else if (raw.startsWith("@@") || raw === "") {
      lines.push({ kind: "context", text: raw });
    } else {
      lines.push({ kind: "context", text: raw.startsWith(" ") ? raw.slice(1) : raw });
    }
  }
  return { lines, additions, deletions };
}

export const WebSearchTool: ToolCallMessagePartComponent<WebSearchArgs, WebSearchResult> = (p) => {
  const results = (p.result?.results ?? []).filter((r) => typeof r?.url === "string").map((r) => ({ title: r.title ?? "", url: r.url! }));
  const searching = p.result === undefined && p.status.type === "running";
  return (
    <div className="py-1" data-testid="tool-web-search">
      <WebSearch query={p.args.query ?? ""} results={results} searching={searching} searchingLabel={t.searching} readLabel={t.readSources(results.length)} />
    </div>
  );
};

// `type: "backend"`: codex runs these; we only render.
export const codexToolkit = defineToolkit({
  commandExecution: { type: "backend", render: CommandExecutionTool },
  fileChange: { type: "backend", render: FileChangeTool },
  webSearch: { type: "backend", render: WebSearchTool },
});

export const chatConfig = AuiConfig({ tools: Tools({ toolkit: codexToolkit }) });
