// A sub-agent's conversation in a workbench tab: live (its channel joined
// here, its own sub-agents' too), read-only, with the way to its own page
// where it can be spoken to. Under a runtime of its own so the thread
// elements and the toolkit draw it exactly like the main conversation.
import { AssistantRuntimeProvider, useExternalStoreRuntime } from "@assistant-ui/react";
import { useMemo } from "react";
import { Link, useParams } from "react-router";
import { toMessages, subagentsOf } from "@/core/chat/messages";
import { runningTurnId } from "@/core/chat/thread";
import { useThreadView } from "@/core/chat/useThreadView";
import { useThreadViews } from "@/core/chat/useThreadViews";
import { ReadOnlyThread } from "@/ui/components/assistant-ui/elements/thread.aui";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { useChatMaybe } from "@/ui/chat/ChatProvider";
import { chatConfig } from "@/ui/chat/toolkit";
import { t } from "@/ui/strings";

export function AgentTab({ threadId, rowId, name }: { threadId: string; rowId: string | null; name: string }) {
  const { slug } = useParams();
  // the parent's page already follows its children (and theirs): share that
  // view; join the channel only when the thread on screen is another one
  const chat = useChatMaybe();
  const shared = chat?.subviews[threadId];
  const own = useThreadView(shared ? undefined : threadId);
  const ownSubviews = useThreadViews(
    useMemo(() => (shared ? [] : [...subagentsOf(own.view).keys()]), [shared, own.view]),
    (v) => [...subagentsOf(v).keys()],
  );
  const view = shared ?? own.view;
  const subviews = shared ? chat!.subviews : ownSubviews;
  const ready = shared ? true : own.ready;
  const error = shared ? null : own.error;
  const running = runningTurnId(view) !== null;
  const adapter = useMemo(
    () => ({
      messages: toMessages(view, subviews),
      convertMessage: (m: ReturnType<typeof toMessages>[number]) => m,
      isRunning: running,
      // read-only: a word to the child goes from its own page
      onNew: async () => {},
    }),
    [view, subviews, running],
  );
  const runtime = useExternalStoreRuntime(adapter);
  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="agent-tab">
      <div className="border-border/60 text-muted-foreground flex items-center gap-3 border-b px-4 py-1.5 text-xs">
        <span className="text-foreground font-mono">{name}</span>
        <span>{running ? t.subagentWorking : t.subagentDone}</span>
        {rowId && slug ? (
          <Link to={`/p/${slug}/t/${rowId}`} className="text-primary ml-auto underline-offset-2 hover:underline">
            {t.subagentPage}
          </Link>
        ) : null}
      </div>
      {error ? <p className="text-destructive p-4 text-sm">{error}</p> : null}
      {!ready && !error ? <Skeleton className="m-4 h-16" /> : null}
      <div className="min-h-0 flex-1">
        <AssistantRuntimeProvider runtime={runtime} config={chatConfig}>
          <ReadOnlyThread />
        </AssistantRuntimeProvider>
      </div>
    </div>
  );
}
