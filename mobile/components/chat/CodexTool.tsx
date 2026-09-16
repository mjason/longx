// The renderers for codex's items as assistant-ui tool-call parts (the
// shapes core/chat/messages.ts makes): commands, file changes, searches,
// dynamic tools, approvals, questions, sub-agents. Built from the native
// elements (approval-card, agent-status, surfaces) plus two rows of our own
// — a command with its output, a file change with its files — since the
// native catalog has no tool-call / terminal-block / code-diff yet.
import { useAuiState, type ToolCallMessagePartComponent } from "@assistant-ui/react-native";
import { ChevronDown, ChevronRight, FileDiff, Globe, Terminal, Wrench } from "lucide-react-native";
import { useState } from "react";
import { Pressable, Text, TextInput, View } from "react-native";
import { AgentStatus } from "@/components/assistant-ui/elements/agent-status";
import { ApprovalCard } from "@/components/assistant-ui/elements/approval-card";
import { Icon } from "@/components/ui/icon";
import type { CodexExtras } from "@/core/chat/adapter";
import type { AutoReview } from "@/core/chat/messages";
import { t } from "@/lib/strings";

const s = t.thread;

type Approval = { id: string; prompt: string; options: { id: string; label: string; kind?: string }[] };

/** the row every invocation gets: an icon, a verb, a mono chip, a mark; open when running or failed */
function ToolRow({
  icon,
  verb,
  chip,
  running,
  failed,
  children,
  defaultOpen,
}: {
  icon: typeof Terminal;
  verb: string;
  chip: string;
  running: boolean;
  failed: boolean;
  children?: React.ReactNode;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen ?? (running || failed));
  const canOpen = !!children;
  return (
    <View className="my-1">
      <Pressable onPress={() => canOpen && setOpen((o) => !o)} className="min-h-9 flex-row items-center gap-2 py-1" testID="tool-row">
        {canOpen ? <Icon as={open ? ChevronDown : ChevronRight} className="text-muted-foreground size-3.5" /> : <View className="w-3.5" />}
        <Icon as={icon} className="text-muted-foreground size-3.5" />
        <Text className="text-muted-foreground shrink-0 text-sm">{verb}</Text>
        <Text className="bg-muted text-foreground min-w-0 shrink rounded px-1.5 py-0.5 font-mono text-xs" numberOfLines={1}>
          {chip}
        </Text>
        <View className="flex-1" />
        {running ? (
          <View className="bg-warning size-2 rounded-full" />
        ) : failed ? (
          <Text className="text-destructive text-xs">✕</Text>
        ) : (
          <Text className="text-success text-xs">✓</Text>
        )}
      </Pressable>
      {open && children ? <View className="ml-5">{children}</View> : null}
    </View>
  );
}

function Mono({ text, testID }: { text: string; testID?: string }) {
  return (
    <View className="bg-muted rounded-lg p-3">
      <Text className="text-foreground font-mono text-xs leading-5" selectable testID={testID}>
        {text.length > 6000 ? `${text.slice(0, 6000)}\n…` : text}
      </Text>
    </View>
  );
}

function ReviewLine({ review, onOverride }: { review: AutoReview | undefined; onOverride?: () => void }) {
  if (!review) return null;
  if (review.status === "inProgress") return <Text className="text-muted-foreground py-1 text-xs">{s.autoReviewRunning}</Text>;
  if (review.status === "approved") return <Text className="text-success py-1 text-xs">{s.autoReviewApproved}</Text>;
  if (review.status === "denied" && !review.userApproved)
    return (
      <View className="border-destructive/40 bg-destructive/5 my-1 gap-2 rounded-lg border p-3">
        <Text className="text-destructive text-sm">{s.autoReviewDenied}</Text>
        {review.rationale ? <Text className="text-muted-foreground text-xs">{review.rationale}</Text> : null}
        {onOverride ? (
          <Pressable onPress={onOverride} className="bg-primary self-start rounded-full px-3.5 py-1.5" testID="review-override">
            <Text className="text-primary-foreground text-sm">{s.stillAllow}</Text>
          </Pressable>
        ) : null}
      </View>
    );
  return null;
}

function ApprovalBlock({ approval, command, respond }: { approval: Approval; command: string; respond: (optionId: string) => void }) {
  const session = approval.options.find((o) => o.id === "accept_for_session");
  return (
    <ApprovalCard
      state="request"
      title={s.needsApproval}
      subtitle={approval.prompt}
      command={command}
      onAllowOnce={() => respond(approval.options.find((o) => o.id === "accept")?.id ?? approval.options[0]!.id)}
      onAlwaysAllow={session ? () => respond(session.id) : undefined}
      onDeny={() => respond(approval.options.find((o) => o.id === "decline" || o.id === "cancel")?.id ?? "decline")}
    />
  );
}

export const CodexTool: ToolCallMessagePartComponent = (part) => {
  const { toolName, args, result, status, isError, approval, respondToApproval } = part as typeof part & { approval?: Approval };
  const extras = useAuiState((st) => st.thread.extras as unknown as CodexExtras);
  const a = args as Record<string, unknown>;
  const r = result as Record<string, unknown> | undefined;
  const running = status.type === "running" || (status.type === "requires-action" && !approval);
  const failed = !!isError;
  const review = a["review"] as AutoReview | undefined;
  const respond = (optionId: string) => void respondToApproval({ optionId });
  const pending = approval && (part as { approval?: { approved?: boolean } }).approval?.approved === undefined ? approval : undefined;

  switch (toolName) {
    case "commandExecution": {
      const command = String(a["command"] ?? "");
      const output = String(r?.["output"] ?? part.artifact ?? "");
      const exit = r?.["exitCode"] as number | null | undefined;
      const st = String(r?.["status"] ?? "");
      const verb = st === "declined" ? s.declined : st === "failed" && !output ? s.failed : r ? s.ran : s.running_;
      return (
        <View>
          {pending ? <ApprovalBlock approval={pending} command={command} respond={respond} /> : null}
          <ReviewLine review={review} onOverride={review ? () => void extras.approveDeniedReview(review.id) : undefined} />
          <ToolRow icon={Terminal} verb={verb} chip={command} running={running && !pending} failed={failed}>
            {output ? <Mono text={output} testID="command-output" /> : null}
            {typeof exit === "number" && exit !== 0 ? <Text className="text-destructive mt-1 text-xs">{s.exit(exit)}</Text> : null}
          </ToolRow>
        </View>
      );
    }
    case "fileChange": {
      const changes = (a["changes"] as { path: string; kind: string; diff?: string }[]) ?? [];
      const chip = changes.length === 1 ? String(changes[0]!.path).split("/").pop() ?? "" : `${changes.length} 个文件`;
      return (
        <View>
          {pending ? <ApprovalBlock approval={pending} command={changes.map((c) => c.path).join("\n")} respond={respond} /> : null}
          <ReviewLine review={review} onOverride={review ? () => void extras.approveDeniedReview(review.id) : undefined} />
          <ToolRow icon={FileDiff} verb={r ? s.changed : s.changing} chip={chip} running={running && !pending} failed={failed}>
            {changes.map((c) => (
              <View key={c.path} className="mb-2">
                <Text className="text-foreground font-mono text-xs">
                  {c.kind === "add" ? "+ " : c.kind === "delete" ? "− " : "± "}
                  {c.path}
                </Text>
                {c.diff ? <Mono text={c.diff} /> : null}
              </View>
            ))}
          </ToolRow>
        </View>
      );
    }
    case "webSearch":
      return <ToolRow icon={Globe} verb={r ? s.searched : s.searching} chip={String(a["query"] ?? "")} running={running} failed={failed} />;
    case "permissions":
      return pending ? (
        <ApprovalBlock approval={pending} command={[...((a["lines"] as string[]) ?? []), a["reason"] ? String(a["reason"]) : ""].filter(Boolean).join("\n")} respond={respond} />
      ) : (
        <ToolRow icon={Wrench} verb={s.permissions} chip={((a["lines"] as string[]) ?? []).join(" · ")} running={false} failed={failed} />
      );
    case "autoReview":
      return <ReviewLine review={{ ...(a["review"] as AutoReview), status: (r?.["status"] as AutoReview["status"]) ?? "inProgress" }} />;
    case "requestUserInput":
      return <Questions requestId={String(a["requestId"])} questions={(a["questions"] as Question[]) ?? []} answered={!!result} />;
    case "subagent": {
      const name = String(a["name"] ?? a["agentPath"] ?? "agent").split("/").pop() ?? "agent";
      const kind = String(a["kind"] ?? "started");
      return (
        <View className="my-1">
          {pending ? <ApprovalBlock approval={pending} command={String(a["request"] ?? "")} respond={respond} /> : null}
          <AgentStatus
            state={kind === "completed" ? "done" : kind === "interrupted" ? "failed" : pending ? "waiting" : "working"}
            label={s.subagent(name)}
            trailing={<Text className="text-muted-foreground text-xs">{s.agentStates[kind] ?? kind}</Text>}
          />
        </View>
      );
    }
    case "collab":
      return <Text className="text-muted-foreground py-1 text-xs">{String(a["tool"] ?? "collab")}</Text>;
    default:
      return (
        <ToolRow icon={Wrench} verb={r ? s.called(toolName) : s.calling(toolName)} chip={summarize(a)} running={running} failed={failed}>
          {r ? <Mono text={JSON.stringify(r, null, 2)} /> : null}
        </ToolRow>
      );
  }
};

function summarize(args: Record<string, unknown>): string {
  const text = JSON.stringify(args);
  return text.length > 60 ? `${text.slice(0, 60)}…` : text;
}

type Question = { id: string; header?: string; question: string; options?: { label: string; description?: string }[] };

function Questions({ requestId, questions, answered }: { requestId: string; questions: Question[]; answered: boolean }) {
  const extras = useAuiState((st) => st.thread.extras as unknown as CodexExtras);
  const [values, setValues] = useState<Record<string, string>>({});
  const [sent, setSent] = useState(answered);
  if (sent) return <Text className="text-muted-foreground py-1 text-xs">{s.answer}：✓</Text>;
  return (
    <View className="border-border bg-card my-1 gap-3 rounded-xl border p-3" testID="questions">
      <Text className="text-foreground text-sm font-medium">{s.question}</Text>
      {questions.map((q) => (
        <View key={q.id} className="gap-1.5">
          <Text className="text-foreground text-sm">{q.question}</Text>
          {q.options?.length ? (
            <View className="flex-row flex-wrap gap-2">
              {q.options.map((o) => (
                <Pressable
                  key={o.label}
                  onPress={() => setValues((v) => ({ ...v, [q.id]: o.label }))}
                  className={`rounded-full border px-3 py-1.5 ${values[q.id] === o.label ? "bg-primary border-primary" : "border-border"}`}
                >
                  <Text className={`text-sm ${values[q.id] === o.label ? "text-primary-foreground" : "text-foreground"}`}>{o.label}</Text>
                </Pressable>
              ))}
            </View>
          ) : (
            <TextInput
              value={values[q.id] ?? ""}
              onChangeText={(text) => setValues((v) => ({ ...v, [q.id]: text }))}
              className="border-input bg-background text-foreground min-h-10 rounded-lg border px-3 py-2 text-sm"
              multiline
            />
          )}
        </View>
      ))}
      <Pressable
        onPress={() => {
          setSent(true);
          void extras.answerRequest(requestId, Object.fromEntries(questions.map((q) => [q.id, [values[q.id] ?? ""]])));
        }}
        className="bg-primary self-end rounded-full px-4 py-2"
        testID="questions-submit"
      >
        <Text className="text-primary-foreground text-sm">{s.answer}</Text>
      </Pressable>
    </View>
  );
}
