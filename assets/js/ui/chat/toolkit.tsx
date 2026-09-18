import { cn } from "@/lib/utils";
import {
  ShimmerLabel,
  mono,
} from "@/ui/components/assistant-ui/elements/surfaces";
// How the kernel's items render inside an assistant message — with the
// assistant-ui "Tool use" elements, nothing of our own: every invocation is
// a ToolCall row (verb, chip, check) whose body is the element for that
// kind of work (terminal-block, file-tree + code-diff, web-search,
// tool-error); a tool's ask (Context.ask) is an elicitation-form. Dynamic
// `ns.tool` calls fall through to the ToolFallback element. An ask answers
// through `ActionAnswerContext` (ChatProvider provides it; a nested
// sub-agent conversation has no thread extras of its own).
import {
  AuiConfig,
  defineToolkit,
  makeAssistantDataUI,
  MessagePartPrimitive,
  MessagePrimitive,
  Tools,
  useToolCallElapsed,
  type ToolCallMessagePartComponent,
  type ToolCallMessagePartProps,
} from "@assistant-ui/react";
import { createContext, useContext, useState, type ReactNode } from "react";
import { toast } from "sonner";
import type { ThreadExtras } from "@/core/chat/adapter";
import {
  AgentStatus,
  type AgentState,
} from "@/ui/components/assistant-ui/elements/agent-status";
import { MarkdownText } from "@/ui/components/assistant-ui/elements/markdown-text";
import { AssistantParts } from "@/ui/components/assistant-ui/elements/thread.aui";
import {
  CodeDiff,
  type DiffLine,
} from "@/ui/components/assistant-ui/elements/code-diff";
import {
  ElicitationForm,
  type ElicitationField,
} from "@/ui/components/assistant-ui/elements/elicitation-form";
import {
  FileTree,
  type FileTreeNode,
} from "@/ui/components/assistant-ui/elements/file-tree";
import { GenerativeTree } from "@/ui/components/assistant-ui/elements/generative-ui";
import { TerminalBlock } from "@/ui/components/assistant-ui/elements/terminal-block";
import { ToolCall } from "@/ui/components/assistant-ui/elements/tool-call";
import { ToolError } from "@/ui/components/assistant-ui/elements/tool-error";
import {
  WebSearch,
  domainOf,
} from "@/ui/components/assistant-ui/elements/web-search";
import { t } from "@/ui/strings";

type CommandArgs = { command?: string; fullCommand?: string; cwd?: string };
type CommandResult = {
  status: string;
  exitCode: number | null;
  output: string;
  durationMs?: number | null;
};

type FileChange = {
  path: string;
  kind?: { type?: string; move_path?: string | null };
  diff?: string;
};
type FileChangeArgs = { changes?: FileChange[] };
type FileChangeResult = { status: string; output: string };

// every search / page read is a webSearch item; the action says what it was
type WebSearchAction =
  | { type: "search"; query?: string | null; queries?: string[] | null }
  | { type: "openPage"; url?: string | null }
  | { type: "findInPage"; url?: string | null; pattern?: string | null }
  | { type: string };
type WebSearchArgs = { query?: string; action?: WebSearchAction | null };
type WebSearchResult = { results?: { title?: string; url?: string }[] | null };

/** How an ask is answered: the runtime's `answerAction`, provided by ChatProvider for the whole window (nested conversations included). */
export const ActionAnswerContext = createContext<
  ThreadExtras["answerAction"] | null
>(null);

/** A ToolCall row that opens itself while the work runs or when it failed, and can be toggled after. */
function ToolRow({
  label,
  activeLabel,
  query,
  running,
  failed,
  children,
  testId,
}: {
  label: string;
  activeLabel: string;
  query: string;
  running: boolean;
  failed: boolean;
  children: ReactNode;
  testId: string;
}) {
  const [open, setOpen] = useState<boolean | null>(null);
  return (
    <div className="py-1" data-testid={testId}>
      <ToolCall
        label={label}
        activeLabel={activeLabel}
        query={query}
        running={running}
        failed={failed}
        open={open ?? (running || failed)}
        onOpenChange={setOpen}
        className="max-w-none"
      >
        {children}
      </ToolCall>
    </div>
  );
}

export const CommandExecutionTool: ToolCallMessagePartComponent<
  CommandArgs,
  CommandResult
> = (p) => {
  const command = p.args.command ?? "";
  const output =
    p.result?.output ?? (typeof p.artifact === "string" ? p.artifact : "");
  const lines = output ? output.replace(/\n$/, "").split("\n") : [];
  const running = p.result === undefined && p.status.type === "running";
  const failed = p.isError === true || p.status.type === "incomplete";
  const couldNotRun =
    p.result?.status === "failed" && typeof p.result.exitCode !== "number";

  return (
    <ToolRow
      label={t.ranCommand}
      activeLabel={t.runningCommand}
      query={command}
      running={running}
      failed={failed}
      testId="tool-command"
    >
      {couldNotRun ? (
        <ToolError
          name={t.command}
          target={command}
          message={output || t.commandFailed}
          attempt={0}
          maxAttempts={0}
          retrying={false}
        />
      ) : (
        <TerminalBlock
          command={command}
          fullCommand={p.args.fullCommand}
          lines={lines}
          done={!running}
          exitCode={p.result?.exitCode ?? (running ? 0 : null)}
          exitLabel={exitLabel(p)}
        />
      )}
    </ToolRow>
  );
};

function exitLabel(
  p: ToolCallMessagePartProps<CommandArgs, CommandResult>,
): string | undefined {
  if (p.result?.status === "declined") return t.declined;
  if (p.status.type === "incomplete") return t.cancelledTool;
  if (typeof p.result?.exitCode === "number")
    return t.exitCode(p.result.exitCode);
  return undefined;
}

export const FileChangeTool: ToolCallMessagePartComponent<
  FileChangeArgs,
  FileChangeResult
> = (p) => {
  const changes = p.args.changes ?? [];
  const parsed = changes.map((c) => ({
    change: c,
    ...parseDiff(c.diff ?? ""),
  }));
  const running = p.result === undefined && p.status.type === "running";
  const failed = p.isError === true || p.status.type === "incomplete";
  const tree = treeOf(
    parsed.map((d) => ({
      path: d.change.path,
      additions: d.additions,
      deletions: d.deletions,
    })),
  );

  return (
    <ToolRow
      label={t.changedFiles}
      activeLabel={t.changingFiles}
      query={
        changes.length === 1 ? changes[0]!.path : t.fileChanges(changes.length)
      }
      running={running}
      failed={failed}
      testId="tool-file-change"
    >
      <div className="flex flex-col gap-2">
        {changes.length > 1 ? (
          <FileTree
            nodes={tree}
            visibleCount={tree.length}
            totalAdditions={parsed.reduce((n, d) => n + d.additions, 0)}
            totalDeletions={parsed.reduce((n, d) => n + d.deletions, 0)}
            filesLabel={t.fileChanges}
            className="max-w-none"
          />
        ) : null}
        {parsed.map((d) => (
          <CodeDiff
            key={d.change.path}
            filename={changeLabel(d.change)}
            lines={d.lines}
            additions={d.additions}
            deletions={d.deletions}
            className="max-w-none"
          />
        ))}
        {p.result?.status === "declined" ? (
          <p className="text-muted-foreground text-xs">{t.declined}</p>
        ) : null}
      </div>
    </ToolRow>
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
export function treeOf(
  files: { path: string; additions: number; deletions: number }[],
): FileTreeNode[] {
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
    nodes.push({
      path: file.path,
      name: parts.at(-1)!,
      depth: parts.length - 1,
      kind: "file",
      additions: file.additions,
      deletions: file.deletions,
    });
  }
  return nodes;
}

/** A unified diff (one per changed file) → lines the CodeDiff element draws. */
export function parseDiff(diff: string): {
  lines: DiffLine[];
  additions: number;
  deletions: number;
} {
  const lines: DiffLine[] = [];
  let additions = 0;
  let deletions = 0;
  for (const raw of diff.replace(/\n$/, "").split("\n")) {
    if (
      raw.startsWith("+++") ||
      raw.startsWith("---") ||
      raw.startsWith("diff ") ||
      raw.startsWith("index ")
    )
      continue;
    if (raw.startsWith("+")) {
      additions++;
      lines.push({ kind: "added", text: raw.slice(1) });
    } else if (raw.startsWith("-")) {
      deletions++;
      lines.push({ kind: "removed", text: raw.slice(1) });
    } else if (raw.startsWith("@@") || raw === "") {
      lines.push({ kind: "context", text: raw });
    } else {
      lines.push({
        kind: "context",
        text: raw.startsWith(" ") ? raw.slice(1) : raw,
      });
    }
  }
  return { lines, additions, deletions };
}

export const WebSearchTool: ToolCallMessagePartComponent<
  WebSearchArgs,
  WebSearchResult
> = (p) => {
  const results = (p.result?.results ?? [])
    .filter((r) => typeof r?.url === "string")
    .map((r) => ({ title: r.title ?? "", url: r.url! }));
  const searching = p.result === undefined && p.status.type === "running";
  const action = p.args.action;
  const kind =
    action?.type === "openPage"
      ? "open"
      : action?.type === "findInPage"
        ? "find"
        : "search";
  const query =
    kind === "open"
      ? ((action as { url?: string | null }).url ?? p.args.query ?? "")
      : kind === "find"
        ? ((action as { pattern?: string | null }).pattern ??
          p.args.query ??
          "")
        : (p.args.query ?? "");
  const labels =
    kind === "open"
      ? [t.readPage, t.readingPage]
      : kind === "find"
        ? [t.foundInPage, t.findingInPage]
        : [t.searchedWeb, t.searching];
  return (
    <ToolRow
      label={labels[0]!}
      activeLabel={labels[1]!}
      query={query}
      running={searching}
      failed={p.isError === true}
      testId="tool-web-search"
    >
      {kind === "open" ? (
        <ReadPage
          url={query}
          title={results[0]?.title ?? ""}
          running={searching}
        />
      ) : (
        <WebSearch
          query={query}
          results={results}
          searching={searching}
          searchingLabel={labels[1]!}
          readLabel={
            kind === "search" ? t.readSources(results.length) : t.pageRead
          }
          className="max-w-none"
        />
      )}
    </ToolRow>
  );
};

// a page read: one link row (the page's title, its domain), not a search box
function ReadPage({
  url,
  title,
  running,
}: {
  url: string;
  title: string;
  running: boolean;
}) {
  const domain = domainOf(url);
  return (
    <div
      className="flex w-full flex-col gap-1.5 text-xs"
      data-testid="tool-read-page"
    >
      {running ? (
        <ShimmerLabel className="text-foreground/45 relative inline-block leading-none">
          {t.readingPage}
        </ShimmerLabel>
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
        <span className="text-foreground/90 min-w-0 flex-1 truncate text-[13.5px]">
          {title || url}
        </span>
        <span className={cn(mono, "text-foreground/35 shrink-0")}>
          {domain}
        </span>
      </a>
    </div>
  );
}

type ActionArgs = {
  requestId?: string;
  title?: string;
  text?: string;
  url?: string | null;
  fields?: { id: string; label: string }[];
  /** a generative tree (prompt_user): drawn instead of the fields, answered by what the person fires */
  spec?: unknown;
};

// ---- cards: the model's `present` tree (or one a plug pushed with Context.present)

/**
 * A `longx.present` call: the arguments are a tree in the vocabulary
 * (`$type` + props + `children`), drawn as is — the card is the point, so
 * no row to open. While the call still streams the tree may be partial:
 * a shimmer says so.
 */
export const PresentTool: ToolCallMessagePartComponent<Record<string, unknown>, unknown> = (p) => {
  const streaming = p.status.type === "running";
  return (
    <div className="aui-present my-2 flex flex-col gap-2" data-testid="tool-present">
      {streaming ? <ShimmerLabel className="text-xs">{t.presentDrawing}</ShimmerLabel> : null}
      <GenerativeTree tree={p.args} status={streaming ? "streaming" : "done"} />
    </div>
  );
};

/** A `longx.prompt_user` call's own row: the form itself is the ask (ActionTool); this just says the turn waits on it. */
export const PromptUserTool: ToolCallMessagePartComponent<Record<string, unknown>, unknown> = (p) => {
  const waiting = p.status.type === "running" || p.status.type === "requires-action";
  return (
    <div className="text-muted-foreground flex items-center gap-2 py-1 text-xs" data-testid="tool-prompt-user">
      {waiting ? <ShimmerLabel>{t.promptUser}</ShimmerLabel> : <span>{p.isError ? t.declined : t.promptAnswered}</span>}
    </div>
  );
};

/**
 * The kernel's ask (Context.ask): the person has to act — open a
 * link and log in, type a code — before the tool goes on. A link button,
 * the fields as an elicitation form; 已完成 / 取消 answer the request.
 */
export const ActionTool: ToolCallMessagePartComponent<ActionArgs, unknown> = (
  p,
) => {
  const answerAction = useContext(ActionAnswerContext);
  const [values, setValues] = useState<Record<string, string>>({});
  const [state, setState] = useState<"request" | "accepted" | "declined">(
    "request",
  );
  const fields: ElicitationField[] = (p.args.fields ?? []).map((f) => ({
    name: f.id,
    label: f.label,
    value: values[f.id] ?? "",
    kind: "text",
    required: true,
  }));
  const pending = p.status.type === "requires-action" && state === "request";
  const answer = (
    answers: Record<string, unknown>,
    next: "accepted" | "declined",
  ) => {
    if (!p.args.requestId || !answerAction) return;
    setState(next);
    void answerAction(p.args.requestId, answers).catch((error: unknown) => {
      setState("request");
      toast.error(error instanceof Error ? error.message : String(error));
    });
  };
  // a generative tree (prompt_user): the vocabulary's own controls; whatever
  // the person fires — `$action` with its `$input` or the form's values — is
  // the answer, a cancel included (the model reads that they dismissed it)
  if (p.args.spec !== undefined && p.args.spec !== null) {
    return (
      <div className="flex flex-col gap-2 py-1" data-testid="tool-action">
        {p.args.text ? <p className="text-sm">{p.args.text}</p> : null}
        <GenerativeTree
          tree={p.args.spec}
          className={cn(!pending && "pointer-events-none opacity-60")}
          dispatch={
            pending
              ? (action) => {
                  const dismissed = action.type === "cancel" || action.type === "dismiss";
                  answer({ action }, dismissed ? "declined" : "accepted");
                }
              : undefined
          }
        />
        {!pending ? (
          <span className="text-muted-foreground text-xs">
            {state === "declined" ? t.declined : t.answered}
          </span>
        ) : null}
      </div>
    );
  }
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
        state={
          pending ? "request" : state === "declined" ? "declined" : "accepted"
        }
        labels={{
          needsInput: t.awaitingAction,
          send: fields.length ? t.send : t.actionDone,
          decline: t.cancel,
          sent: t.answered,
          declined: t.declined,
          other: t.otherAnswer,
        }}
        onChange={(name, value) => setValues((v) => ({ ...v, [name]: value }))}
        onAccept={() =>
          answer(
            fields.length
              ? Object.fromEntries(
                  fields.map((f) => [f.name, values[f.name] ?? ""]),
                )
              : { done: true },
            "accepted",
          )
        }
        onDecline={() => answer({ cancelled: true }, "declined")}
      />
    </div>
  );
};

// ---- agents: the thread's sub-agents (subAgentActivity), each with its own conversation nested

type SubagentArgs = {
  name: string;
  path: string;
  threadId: string;
  kind: string;
  request?: { title?: string } | null;
};
type SubagentResult = { kind: string };

function elapsedLabel(ms: number | undefined): string | undefined {
  return ms === undefined ? undefined : `${Math.round(ms / 1000)}s`;
}

// a sub-agent's nested conversation: the child's user turns (its task) and
// assistant turns rendered with the same parts as the main thread — the
// toolkit is inherited, so its commands / diffs / asks look the same
const NestedUser = () => (
  <MessagePrimitive.Root
    data-slot="aui_nested-user-message"
    className="text-muted-foreground my-1 text-sm"
  >
    <MessagePrimitive.Parts components={{ Text: MarkdownText }} />
  </MessagePrimitive.Root>
);
const NestedAssistant = () => (
  <MessagePrimitive.Root
    data-slot="aui_nested-assistant-message"
    className="my-1 text-sm"
  >
    <AssistantParts />
  </MessagePrimitive.Root>
);

/** One sub-agent: its state pill (waiting when the child asks the person to act) and its conversation nested. */
export const SubagentTool: ToolCallMessagePartComponent<
  SubagentArgs,
  SubagentResult
> = (p) => {
  const elapsed = useToolCallElapsed();
  const kind = p.result?.kind ?? p.args.kind;
  const done = kind === "completed" || kind === "interrupted";
  const failed = kind === "interrupted";
  const waiting = !done && p.args.request != null;
  const state: AgentState = done ? "done" : waiting ? "waiting" : "working";
  return (
    <ToolRow
      label={failed ? t.subagentInterrupted : t.subagentDone}
      activeLabel={t.subagentWorking}
      query={p.args.name}
      running={!done}
      failed={failed}
      testId="tool-subagent"
    >
      <div className="flex flex-col gap-2">
        <AgentStatus
          state={state}
          label={
            waiting
              ? p.args.request?.title || t.subagentNeedsAction
              : (t.subagentState[kind] ?? kind)
          }
          elapsed={elapsedLabel(elapsed)}
          action={null}
          className="self-start pe-3.5"
        />
        {p.messages?.length ? (
          <div
            className="border-border/60 flex flex-col border-s ps-3"
            data-testid="subagent-messages"
          >
            <MessagePartPrimitive.Messages>
              {({ message }) =>
                message.role === "user" ? <NestedUser /> : <NestedAssistant />
              }
            </MessagePartPrimitive.Messages>
          </div>
        ) : null}
      </div>
    </ToolRow>
  );
};

// ---- the kernel compacted the conversation here (older turns summarised away)

export function CompactionView() {
  return (
    <div
      role="separator"
      aria-label={t.compacted}
      className="text-muted-foreground my-2 flex items-center gap-2 text-[11px]"
      data-testid="compaction"
    >
      <span className="bg-border h-px flex-1" />
      <span>{t.compacted}</span>
      <span className="bg-border h-px flex-1" />
    </div>
  );
}

export const CompactionUI = makeAssistantDataUI<{ id: string }>({
  name: "compaction",
  render: () => <CompactionView />,
});

// `type: "backend"`: the kernel runs these; we only render. `display: "standalone"`
// keeps them out of the collapsible "n tool calls" trace group — what the
// agent ran and changed is the point of this UI, not a trace to fold away;
// dynamic `ns.tool` calls stay in the group via ToolFallback.
export const longxToolkit = defineToolkit({
  commandExecution: {
    type: "backend",
    render: CommandExecutionTool,
    display: "standalone",
  },
  fileChange: {
    type: "backend",
    render: FileChangeTool,
    display: "standalone",
  },
  webSearch: { type: "backend", render: WebSearchTool, display: "standalone" },
  action: { type: "backend", render: ActionTool, display: "standalone" },
  subagent: { type: "backend", render: SubagentTool, display: "standalone" },
  // the cards (Longx.Agent.Plugs.Present): the tree is the arguments
  "longx.present": { type: "backend", render: PresentTool, display: "standalone" },
  "longx.prompt_user": { type: "backend", render: PromptUserTool, display: "standalone" },
});

export const chatConfig = AuiConfig({
  tools: Tools({ toolkit: longxToolkit }),
});
