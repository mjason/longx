import { cn } from "@/lib/utils";
import { ShimmerLabel, mono } from "@/ui/components/assistant-ui/elements/surfaces";
// How codex's items render inside an assistant message — with the
// assistant-ui "Tool use" elements, nothing of our own: every invocation is
// a ToolCall row (verb, chip, check) whose body is the element for that
// kind of work (terminal-block, file-tree + code-diff, web-search,
// tool-error); an approval is an approval-card above the row, a question
// an elicitation-form. Dynamic `ns.tool` calls fall through to the
// ToolFallback element. Approvals answer through assistant-ui's
// `respondToApproval` seam (option id = our decision), questions through
// the runtime's extras.
import { AuiConfig, defineToolkit, makeAssistantDataUI, MessagePartPrimitive, MessagePrimitive, Tools, useAui, useAuiState, useToolCallElapsed, type ToolCallMessagePartComponent, type ToolCallMessagePartProps } from "@assistant-ui/react";
import { useState, type ReactNode } from "react";
import { CheckIcon, Loader2Icon, ShieldAlert, ShieldQuestion } from "lucide-react";
import { toast } from "sonner";
import type { CodexExtras } from "@/core/chat/adapter";
import type { AutoReview } from "@/core/chat/messages";
import type { PlanStep } from "@/core/chat/thread";
import { AgentHandoff } from "@/ui/components/assistant-ui/elements/agent-handoff";
import { AgentPlan, type PlanStepState } from "@/ui/components/assistant-ui/elements/agent-plan";
import { AgentStatus, type AgentState } from "@/ui/components/assistant-ui/elements/agent-status";
import { ApprovalCard, type ApprovalLabels } from "@/ui/components/assistant-ui/elements/approval-card";
import { MarkdownText } from "@/ui/components/assistant-ui/elements/markdown-text";
import { SubagentList } from "@/ui/components/assistant-ui/elements/subagent-list";
import { AssistantParts } from "@/ui/components/assistant-ui/elements/thread.aui";
import { CodeDiff, type DiffLine } from "@/ui/components/assistant-ui/elements/code-diff";
import { ElicitationForm, type ElicitationField } from "@/ui/components/assistant-ui/elements/elicitation-form";
import { FileTree, type FileTreeNode } from "@/ui/components/assistant-ui/elements/file-tree";
import { TerminalBlock } from "@/ui/components/assistant-ui/elements/terminal-block";
import { ToolCall } from "@/ui/components/assistant-ui/elements/tool-call";
import { ToolError } from "@/ui/components/assistant-ui/elements/tool-error";
import { WebSearch, domainOf } from "@/ui/components/assistant-ui/elements/web-search";
import { t } from "@/ui/strings";

type CommandArgs = { command?: string; fullCommand?: string; cwd?: string; review?: AutoReview };
type CommandResult = { status: string; exitCode: number | null; output: string; durationMs?: number | null };

type FileChange = { path: string; kind?: { type?: string; move_path?: string | null }; diff?: string };
type FileChangeArgs = { changes?: FileChange[]; review?: AutoReview };
type FileChangeResult = { status: string; output: string };

// codex records every web.run call as a webSearch item; the action says what it was
type WebSearchAction = { type: "search"; query?: string | null; queries?: string[] | null } | { type: "openPage"; url?: string | null } | { type: "findInPage"; url?: string | null; pattern?: string | null } | { type: string };
type WebSearchArgs = { query?: string; action?: WebSearchAction | null };
type WebSearchResult = { results?: { title?: string; url?: string }[] | null };


type ApprovalSeam = Pick<ToolCallMessagePartProps, "approval" | "respondToApproval">;

function pendingApproval(p: ApprovalSeam) {
  return p.approval && p.approval.approved === undefined && p.approval.resolution === undefined ? p.approval : undefined;
}

/** The three codex answers as assistant-ui option ids; disabled once one is sent. */
// the card's buttons come from the approval's options (what codex offered:
// a session variant only when it listed one), labels included
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
  const options = (p.approval?.options ?? []) as { id: string; kind: string; label: string }[];
  const once = options.find((o) => o.kind === "allow-once");
  const always = options.find((o) => o.kind === "allow-always");
  const deny = options.find((o) => o.kind === "reject-once");
  return {
    disabled: sent,
    labels: { allowOnce: once?.label ?? t.allowOnce, alwaysAllow: always?.label ?? t.allowSession, deny: deny?.label ?? t.deny } as ApprovalLabels,
    onAllowOnce: () => answer(once?.id ?? "accept"),
    ...(always ? { onAlwaysAllow: () => answer(always.id) } : {}),
    onDeny: () => answer(deny?.id ?? "decline"),
  };
}

/**
 * codex's automatic approval review of the action a row shows: one quiet
 * line while it runs and once approved; a denial is an approval-card in its
 * denied state whose 仍然允许 hands the action back as approved by the
 * person (extras.approveDeniedReview) and tells the model to go on.
 */
function AutoReviewVerdict({ review, command }: { review: AutoReview; command: ReactNode }) {
  const approve = useAuiState((s) => (s.thread.extras as CodexExtras | undefined)?.approveDeniedReview);
  const aui = useAui();
  const [sent, setSent] = useState(false);
  const rationale = review.rationale ? `：${review.rationale}` : "";
  const risk = review.riskLevel ? ` · ${t.autoReview.risk(review.riskLevel)}` : "";

  if (review.status === "inProgress") {
    return (
      <p className="text-foreground/55 flex items-center gap-1.5 py-1 text-xs" data-testid="auto-review">
        <Loader2Icon className="size-3.5 animate-spin" />
        {t.autoReview.running}
      </p>
    );
  }
  if (review.status !== "denied") {
    const label = review.status === "approved" ? t.autoReview.approved : review.status === "timedOut" ? t.autoReview.timedOut : t.autoReview.aborted;
    return (
      <p className="text-foreground/55 flex items-start gap-1.5 py-1 text-xs" data-testid="auto-review">
        <CheckIcon className="mt-0.5 size-3.5 shrink-0 text-emerald-500" />
        <span>
          {label}
          {risk}
          {rationale}
        </span>
      </p>
    );
  }
  const override = () => {
    if (!approve || sent) return;
    setSent(true);
    void approve(review.id)
      .then(() => aui.thread.append({ role: "user", content: [{ type: "text", text: t.autoReview.continueAfterOverride }] }))
      .catch((error: unknown) => {
        setSent(false);
        toast.error(error instanceof Error ? error.message : String(error));
      });
  };
  return (
    <div className="py-1" data-testid="auto-review">
      <ApprovalCard
        state={review.userApproved ? "done" : "denied"}
        title={t.autoReview.denied}
        subtitle={`${review.riskLevel ? t.autoReview.risk(review.riskLevel) : ""}${rationale}`}
        icon={<ShieldAlert className="size-4" />}
        command={command}
        labels={{ allowOnce: t.allowOnce, alwaysAllow: t.allowSession, deny: t.deny, denied: t.declined, done: t.autoReview.overridden, override: t.autoReview.override }}
        disabled={sent}
        {...(review.userApproved || !approve ? {} : { onOverride: override })}
      />
    </div>
  );
}

/** A ToolCall row that opens itself while the work runs or when it failed, and can be toggled after. */
function ToolRow({ label, activeLabel, query, running, failed, children, testId }: { label: string; activeLabel: string; query: string; running: boolean; failed: boolean; children: ReactNode; testId: string }) {
  const [open, setOpen] = useState<boolean | null>(null);
  return (
    <div className="py-1" data-testid={testId}>
      <ToolCall label={label} activeLabel={activeLabel} query={query} running={running} failed={failed} open={open ?? (running || failed)} onOpenChange={setOpen} className="max-w-none">
        {children}
      </ToolCall>
    </div>
  );
}

export const CommandExecutionTool: ToolCallMessagePartComponent<CommandArgs, CommandResult> = (p) => {
  const actions = useApprovalActions(p);
  const approval = pendingApproval(p);
  const command = p.args.command ?? "";
  const output = p.result?.output ?? (typeof p.artifact === "string" ? p.artifact : "");
  const lines = output ? output.replace(/\n$/, "").split("\n") : [];
  const running = p.result === undefined && p.status.type === "running";
  const failed = p.isError === true || p.status.type === "incomplete";
  const couldNotRun = p.result?.status === "failed" && typeof p.result.exitCode !== "number";

  return (
    <>
      {approval ? (
        <div className="py-1">
          <ApprovalCard state="request" title={t.approvalNeeded} subtitle={approval.prompt ?? t.approveCommand} command={p.args.fullCommand ?? command} {...actions} />
        </div>
      ) : null}
      {p.args.review ? <AutoReviewVerdict review={p.args.review} command={p.args.fullCommand ?? command} /> : null}
      <ToolRow label={t.ranCommand} activeLabel={t.runningCommand} query={command} running={running || approval !== undefined} failed={failed} testId="tool-command">
        {couldNotRun ? (
          <ToolError name={t.command} target={command} message={output || t.commandFailed} attempt={0} maxAttempts={0} retrying={false} />
        ) : (
          <TerminalBlock command={command} fullCommand={p.args.fullCommand} lines={lines} done={!running} exitCode={p.result?.exitCode ?? (running ? 0 : null)} exitLabel={exitLabel(p)} />
        )}
      </ToolRow>
      {/* below the row, not inside it: a finished command's row is folded, the hint must not be */}
    </>
  );
};

type PermissionsArgs = { reason?: string | null; lines?: string[] };

/**
 * codex's request_permissions: the agent asks for directories / the network
 * for the rest of the turn or session — an approval card listing them,
 * granted or refused through the same respond path (no item of its own).
 */
export const PermissionsTool: ToolCallMessagePartComponent<PermissionsArgs, unknown> = (p) => {
  const actions = useApprovalActions(p);
  const approval = pendingApproval(p);
  const lines = p.args.lines ?? [];
  const body = (
    <ul className="flex flex-col gap-0.5" data-testid="permissions-lines">
      {lines.map((l) => (
        <li key={l}>{l}</li>
      ))}
    </ul>
  );
  if (!approval) {
    return (
      <ToolRow label={t.permissionsAsked} activeLabel={t.permissionsAsked} query={lines.join("、")} running={false} failed={false} testId="tool-permissions">
        {body}
      </ToolRow>
    );
  }
  return (
    <div className="py-1" data-testid="tool-permissions">
      <ApprovalCard state="request" title={t.permissionsRequest} subtitle={approval.prompt ?? t.permissionsAsked} icon={<ShieldQuestion className="size-4" />} command={body} {...actions} />
    </div>
  );
};

type AutoReviewArgs = { review: AutoReview; reason?: string | null; lines?: string[]; command?: string; fullCommand?: string };

/**
 * An automatic review with no item of its own (a request_permissions call
 * the reviewer judged): a row naming what was asked, the verdict above it.
 */
export const AutoReviewTool: ToolCallMessagePartComponent<AutoReviewArgs, unknown> = (p) => {
  const lines = p.args.lines ?? [];
  const body = (
    <div className="flex flex-col gap-1">
      {p.args.reason ? <p>{p.args.reason}</p> : null}
      <ul className="flex flex-col gap-0.5" data-testid="permissions-lines">
        {lines.map((l) => (
          <li key={l}>{l}</li>
        ))}
      </ul>
    </div>
  );
  const query = p.args.command ?? [p.args.reason, lines.join("、")].filter((x) => x).join(" · ");
  // a denial is the card alone — it already shows what was asked
  return (
    <div data-testid="tool-auto-review">
      <AutoReviewVerdict review={p.args.review} command={p.args.fullCommand ?? body} />
      {p.args.review.status === "denied" ? null : (
        <ToolRow label={t.autoReview.reviewed} activeLabel={t.autoReview.running} query={query} running={p.args.review.status === "inProgress"} failed={false} testId="tool-auto-review-row">
          {body}
        </ToolRow>
      )}
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
  const parsed = changes.map((c) => ({ change: c, ...parseDiff(c.diff ?? "") }));
  const running = p.result === undefined && p.status.type === "running";
  const failed = p.isError === true || p.status.type === "incomplete";
  const tree = treeOf(parsed.map((d) => ({ path: d.change.path, additions: d.additions, deletions: d.deletions })));

  return (
    <>
      {approval ? (
        <div className="py-1">
          <ApprovalCard
            state="request"
            title={t.approvalNeeded}
            subtitle={approval.prompt ?? t.approveFileChange}
            command={
              <ul>
                {changes.map((c) => (
                  <li key={c.path}>{changeLabel(c)}</li>
                ))}
              </ul>
            }
            {...actions}
          />
        </div>
      ) : null}
      {p.args.review ? (
        <AutoReviewVerdict
          review={p.args.review}
          command={
            <ul>
              {changes.map((c) => (
                <li key={c.path}>{c.path}</li>
              ))}
            </ul>
          }
        />
      ) : null}
      <ToolRow label={t.changedFiles} activeLabel={t.changingFiles} query={changes.length === 1 ? changes[0]!.path : t.fileChanges(changes.length)} running={running || approval !== undefined} failed={failed} testId="tool-file-change">
        <div className="flex flex-col gap-2">
          {changes.length > 1 ? (
            <FileTree nodes={tree} visibleCount={tree.length} totalAdditions={parsed.reduce((n, d) => n + d.additions, 0)} totalDeletions={parsed.reduce((n, d) => n + d.deletions, 0)} filesLabel={t.fileChanges} className="max-w-none" />
          ) : null}
          {parsed.map((d) => (
            <CodeDiff key={d.change.path} filename={changeLabel(d.change)} lines={d.lines} additions={d.additions} deletions={d.deletions} className="max-w-none" />
          ))}
          {p.result?.status === "declined" ? <p className="text-muted-foreground text-xs">{t.declined}</p> : null}
        </div>
      </ToolRow>
    </>
  );
};

function changeLabel(c: FileChange): string {
  const kind = c.kind?.type;
  if (kind === "add") return `+ ${c.path}`;
  if (kind === "delete") return `− ${c.path}`;
  if (c.kind?.move_path) return `${c.path} → ${c.kind.move_path}`;
  return c.path;
}

/** Files (with their churn) → the FileTree element's nodes: folders first, depth from the path. */
export function treeOf(files: { path: string; additions: number; deletions: number }[]): FileTreeNode[] {
  const nodes: FileTreeNode[] = [];
  const seen = new Set<string>();
  for (const file of [...files].sort((a, b) => a.path.localeCompare(b.path))) {
    const parts = file.path.split("/");
    for (let depth = 0; depth < parts.length - 1; depth++) {
      const folder = parts.slice(0, depth + 1).join("/");
      if (seen.has(folder)) continue;
      seen.add(folder);
      nodes.push({ path: folder, name: parts[depth]!, depth, kind: "folder" });
    }
    nodes.push({ path: file.path, name: parts.at(-1)!, depth: parts.length - 1, kind: "file", additions: file.additions, deletions: file.deletions });
  }
  return nodes;
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
  const action = p.args.action;
  const kind = action?.type === "openPage" ? "open" : action?.type === "findInPage" ? "find" : "search";
  const query =
    kind === "open"
      ? ((action as { url?: string | null }).url ?? p.args.query ?? "")
      : kind === "find"
        ? ((action as { pattern?: string | null }).pattern ?? p.args.query ?? "")
        : (p.args.query ?? "");
  const labels = kind === "open" ? [t.readPage, t.readingPage] : kind === "find" ? [t.foundInPage, t.findingInPage] : [t.searchedWeb, t.searching];
  return (
    <ToolRow label={labels[0]!} activeLabel={labels[1]!} query={query} running={searching} failed={p.isError === true} testId="tool-web-search">
      {kind === "open" ? (
        <ReadPage url={query} title={results[0]?.title ?? ""} running={searching} />
      ) : (
        <WebSearch query={query} results={results} searching={searching} searchingLabel={labels[1]!} readLabel={kind === "search" ? t.readSources(results.length) : t.pageRead} className="max-w-none" />
      )}
    </ToolRow>
  );
};

// a page read: one link row (the page's title, its domain), not a search box
function ReadPage({ url, title, running }: { url: string; title: string; running: boolean }) {
  const domain = domainOf(url);
  return (
    <div className="flex w-full flex-col gap-1.5 text-xs" data-testid="tool-read-page">
      {running ? (
        <ShimmerLabel className="text-foreground/45 relative inline-block leading-none">{t.readingPage}</ShimmerLabel>
      ) : null}
      <a
        href={url}
        target="_blank"
        rel="noreferrer"
        className="hover:bg-foreground/[0.03] -mx-2.5 flex items-center gap-2.5 rounded-xl px-2.5 py-1.5 transition-colors"
      >
        <span className="bg-foreground/[0.06] text-foreground/45 flex size-4 shrink-0 items-center justify-center rounded text-[9px] font-medium">
          {domain.charAt(0).toUpperCase()}
        </span>
        <span className="text-foreground/90 min-w-0 flex-1 truncate text-[13.5px]">{title || url}</span>
        <span className={cn(mono, "text-foreground/35 shrink-0")}>{domain}</span>
      </a>
    </div>
  );
}

type Question = { id: string; header?: string; question: string; options?: { label: string; description?: string }[] | null; isOther?: boolean; isSecret?: boolean };
type QuestionsArgs = { requestId?: string; questions?: Question[] };

/** codex's requestUserInput: one form for all its questions; answered through the runtime's extras. */
export const QuestionsTool: ToolCallMessagePartComponent<QuestionsArgs, unknown> = (p) => {
  const extras = useAuiState((s) => s.thread.extras) as CodexExtras | undefined;
  const [values, setValues] = useState<Record<string, string>>({});
  const [state, setState] = useState<"request" | "accepted">("request");
  const questions = p.args.questions ?? [];
  const fields: ElicitationField[] = questions.map((q) => {
    const options = (q.options ?? []).map((o) => o.label);
    return {
      name: q.id,
      label: q.question,
      hint: q.header,
      value: values[q.id] ?? "",
      kind: options.length ? "choice" : "text",
      options,
      freeform: q.isOther ?? false,
      secret: q.isSecret ?? false,
      required: true,
    };
  });
  const pending = p.status.type === "requires-action" && state === "request";
  const submit = () => {
    if (!p.args.requestId || !extras) return;
    setState("accepted");
    void extras.answerRequest(p.args.requestId, Object.fromEntries(questions.map((q) => [q.id, [values[q.id] ?? ""]]))).catch((error: unknown) => {
      setState("request");
      toast.error(error instanceof Error ? error.message : String(error));
    });
  };
  return (
    <div className="py-1" data-testid="tool-questions">
      <ElicitationForm
        server={t.agentAsks}
        message=""
        fields={fields}
        state={pending ? "request" : "accepted"}
        labels={{ needsInput: t.needsAnswer, send: t.send, decline: t.deny, sent: t.answered, declined: t.declined, other: t.otherAnswer }}
        onChange={(name, value) => setValues((v) => ({ ...v, [name]: value }))}
        onAccept={submit}
      />
    </div>
  );
};

type ActionArgs = { requestId?: string; title?: string; text?: string; url?: string | null; fields?: { id: string; label: string }[] };

/**
 * The native kernel's ask (Context.ask): the person has to act — open a
 * link and log in, type a code — before the tool goes on. A link button,
 * the fields as an elicitation form; 已完成 / 取消 answer the request.
 */
export const ActionTool: ToolCallMessagePartComponent<ActionArgs, unknown> = (p) => {
  const extras = useAuiState((s) => s.thread.extras) as CodexExtras | undefined;
  const [values, setValues] = useState<Record<string, string>>({});
  const [state, setState] = useState<"request" | "accepted" | "declined">("request");
  const fields: ElicitationField[] = (p.args.fields ?? []).map((f) => ({ name: f.id, label: f.label, value: values[f.id] ?? "", kind: "text", required: true }));
  const pending = p.status.type === "requires-action" && state === "request";
  const answer = (answers: Record<string, unknown>, next: "accepted" | "declined") => {
    if (!p.args.requestId || !extras) return;
    setState(next);
    void extras.answerAction(p.args.requestId, answers).catch((error: unknown) => {
      setState("request");
      toast.error(error instanceof Error ? error.message : String(error));
    });
  };
  return (
    <div className="flex flex-col gap-2 py-1" data-testid="tool-action">
      {p.args.url ? (
        <a
          href={p.args.url}
          target="_blank"
          rel="noopener noreferrer"
          className="bg-primary text-primary-foreground hover:bg-primary/90 inline-flex w-fit items-center gap-1.5 rounded-full px-3.5 py-1.5 text-xs font-medium"
        >
          {t.openLink}
        </a>
      ) : null}
      <ElicitationForm
        server={p.args.title || t.agentAsks}
        message={p.args.text ?? ""}
        fields={fields}
        state={pending ? "request" : state === "declined" ? "declined" : "accepted"}
        labels={{ needsInput: t.awaitingAction, send: fields.length ? t.send : t.actionDone, decline: t.cancel, sent: t.answered, declined: t.declined, other: t.otherAnswer }}
        onChange={(name, value) => setValues((v) => ({ ...v, [name]: value }))}
        onAccept={() => answer(fields.length ? Object.fromEntries(fields.map((f) => [f.name, values[f.name] ?? ""])) : { done: true }, "accepted")}
        onDecline={() => answer({ cancelled: true }, "declined")}
      />
    </div>
  );
};

// ---- agents: codex's sub-agents and its collaboration tools (multi-agent v2)

type SubagentArgs = { name: string; path: string; threadId: string; kind: string; request?: { command?: string; paths?: string[] } | null };
type SubagentResult = { kind: string };

function elapsedLabel(ms: number | undefined): string | undefined {
  return ms === undefined ? undefined : `${Math.round(ms / 1000)}s`;
}

// a sub-agent's nested conversation: the child's user turns (its task) and
// assistant turns rendered with the same parts as the main thread — the
// toolkit is inherited, so its commands / diffs / approvals look the same
const NestedUser = () => (
  <MessagePrimitive.Root data-slot="aui_nested-user-message" className="text-muted-foreground my-1 text-sm">
    <MessagePrimitive.Parts components={{ Text: MarkdownText }} />
  </MessagePrimitive.Root>
);
const NestedAssistant = () => (
  <MessagePrimitive.Root data-slot="aui_nested-assistant-message" className="my-1 text-sm">
    <AssistantParts />
  </MessagePrimitive.Root>
);

/** One sub-agent: its state pill, the child's approval if it waits on one, and its conversation nested. */
export const SubagentTool: ToolCallMessagePartComponent<SubagentArgs, SubagentResult> = (p) => {
  const actions = useApprovalActions(p);
  const approval = pendingApproval(p);
  const elapsed = useToolCallElapsed();
  const kind = p.result?.kind ?? p.args.kind;
  const done = kind === "completed" || kind === "interrupted";
  const failed = kind === "interrupted";
  const state: AgentState = done ? "done" : approval ? "waiting" : "working";
  const request = p.args.request;
  return (
    <>
      {approval ? (
        <div className="py-1">
          <ApprovalCard
            state="request"
            title={t.approvalNeeded}
            subtitle={approval.prompt ?? t.approveCommand}
            command={request?.command ?? (request?.paths?.length ? <ul>{request.paths.map((path) => <li key={path}>{path}</li>)}</ul> : p.args.name)}
            {...actions}
          />
        </div>
      ) : null}
      <ToolRow label={failed ? t.subagentInterrupted : t.subagentDone} activeLabel={t.subagentWorking} query={p.args.name} running={!done} failed={failed} testId="tool-subagent">
        <div className="flex flex-col gap-2">
          <AgentStatus state={state} label={approval ? t.subagentNeedsApproval : (t.subagentState[kind] ?? kind)} elapsed={elapsedLabel(elapsed)} action={null} className="self-start pe-3.5" />
          {p.messages?.length ? (
            <div className="border-border/60 flex flex-col border-s ps-3" data-testid="subagent-messages">
              <MessagePartPrimitive.Messages>{({ message }) => (message.role === "user" ? <NestedUser /> : <NestedAssistant />)}</MessagePartPrimitive.Messages>
            </div>
          ) : null}
        </div>
      </ToolRow>
    </>
  );
};

type CollabAgent = { threadId: string; name: string; kind?: string | null };
type CollabArgs = { tool?: string; prompt?: string | null; model?: string | null; agents?: CollabAgent[] };
type CollabResult = { status: string; agentsStates?: Record<string, { status?: string; message?: string | null }> };

const FINISHED_AGENT = new Set(["completed", "errored", "interrupted", "shutdown", "notFound"]);
// a sub-agent's latest activity as an agent state (codex 0.154 completes a wait with empty agentsStates)
const KIND_STATE: Record<string, string> = { started: "running", interacted: "running", completed: "completed", interrupted: "interrupted" };

/** codex's collaboration tools: a spawn / message is a handoff, a wait lists the agents and their reported states. */
export const CollabTool: ToolCallMessagePartComponent<CollabArgs, CollabResult> = (p) => {
  const tool = p.args.tool ?? "other";
  const labels = t.collab[tool] ?? t.collab["other"]!;
  const agents = p.args.agents ?? [];
  const running = p.result === undefined && p.status.type === "running";
  const failed = p.isError === true || p.status.type === "incomplete";
  const names = agents.map((a) => a.name);
  const query = names.length ? names.join(", ") : tool === "spawnAgent" ? t.newAgent : "";
  const states = p.result?.agentsStates ?? {};
  const handoff = tool === "spawnAgent" || tool === "sendMessage";
  return (
    <ToolRow label={labels[0]} activeLabel={labels[1]} query={query} running={running} failed={failed} testId="tool-collab">
      {handoff ? (
        <AgentHandoff from={t.mainAgent} to={query || t.newAgent} reason={p.args.prompt ?? ""} carried={p.args.model ? [`${t.agentModel}: ${p.args.model}`] : []} carriedLabel={t.agentTask} settled={!running} />
      ) : (
        <SubagentList
          agents={agents.map((a) => {
            const status = states[a.threadId]?.status ?? (a.kind ? KIND_STATE[a.kind] : undefined);
            return { name: a.name, ...(status ? { model: t.agentStates[status] ?? status } : {}), done: status !== undefined && FINISHED_AGENT.has(status) };
          })}
        />
      )}
    </ToolRow>
  );
};

// ---- the turn's plan (turn/plan/updated), a data part at the top of its message

const STEP_STATE: Record<PlanStep["status"], PlanStepState> = { completed: "done", inProgress: "active", pending: "pending" };

export function PlanView({ explanation, steps }: { explanation: string | null; steps: PlanStep[] }) {
  const done = steps.filter((s) => s.status === "completed").length;
  return (
    <div className="py-2" data-testid="plan">
      <AgentPlan steps={steps.map((s) => s.step)} states={steps.map((s) => STEP_STATE[s.status] ?? "pending")} activeIndex={done} title={t.plan} countLabel={t.planProgress} className="max-w-none" />
      {explanation ? <p className="text-muted-foreground mt-2 text-xs">{explanation}</p> : null}
    </div>
  );
}

/** Registers the plan renderer while mounted (inside the runtime provider). */
export const PlanUI = makeAssistantDataUI<{ explanation: string | null; steps: PlanStep[] }>({
  name: "plan",
  render: ({ data }) => <PlanView explanation={data.explanation} steps={data.steps} />,
});

// ---- codex compacted the conversation here (older turns summarised away)

export function CompactionView() {
  return (
    <div role="separator" aria-label={t.compacted} className="text-muted-foreground my-2 flex items-center gap-2 text-[11px]" data-testid="compaction">
      <span className="bg-border h-px flex-1" />
      <span>{t.compacted}</span>
      <span className="bg-border h-px flex-1" />
    </div>
  );
}

export const CompactionUI = makeAssistantDataUI<{ id: string }>({ name: "compaction", render: () => <CompactionView /> });

// `type: "backend"`: codex runs these; we only render. `display: "standalone"`
// keeps them out of the collapsible "n tool calls" trace group — what the
// agent ran and changed is the point of this UI, not a trace to fold away;
// dynamic `ns.tool` calls stay in the group via ToolFallback.
export const codexToolkit = defineToolkit({
  commandExecution: { type: "backend", render: CommandExecutionTool, display: "standalone" },
  fileChange: { type: "backend", render: FileChangeTool, display: "standalone" },
  webSearch: { type: "backend", render: WebSearchTool, display: "standalone" },
  requestUserInput: { type: "backend", render: QuestionsTool, display: "standalone" },
  action: { type: "backend", render: ActionTool, display: "standalone" },
  permissions: { type: "backend", render: PermissionsTool, display: "standalone" },
  autoReview: { type: "backend", render: AutoReviewTool, display: "standalone" },
  subagent: { type: "backend", render: SubagentTool, display: "standalone" },
  collab: { type: "backend", render: CollabTool, display: "standalone" },
});

export const chatConfig = AuiConfig({ tools: Tools({ toolkit: codexToolkit }) });
