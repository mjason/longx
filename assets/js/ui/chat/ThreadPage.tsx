import { AssistantRuntimeProvider, useExternalStoreRuntime } from "@assistant-ui/react";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo, useState } from "react";
import { useOutletContext, useParams } from "react-router";
import { buildAdapter, type DirtyChange, type DirtyDecision } from "@/core/chat/adapter";
import { runningTurnId } from "@/core/chat/thread";
import { useThreadView } from "@/core/chat/useThreadView";
import { queryKeys, useThreads } from "@/core/projects";
import { Thread, type ThreadComponents } from "@/ui/components/assistant-ui/elements/thread.aui";
import { Alert, AlertDescription } from "@/ui/components/ui/alert";
import { Skeleton } from "@/ui/components/ui/skeleton";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { t } from "@/ui/strings";
import { chatConfig } from "./toolkit";
import { DirtyTreeDialog, type DirtyPrompt } from "./DirtyTreeDialog";
import { TurnBar, type TurnState } from "./TurnBar";

const Welcome = () => (
  <div className="mb-6 flex flex-col items-center px-4 text-center">
    <h1 className="text-2xl font-medium tracking-tight">{t.welcomeChat}</h1>
    <p className="text-muted-foreground mt-2 text-sm">{t.welcomeChatHint}</p>
  </div>
);

// module scope: a new object per render would remount every message
const THREAD_COMPONENTS: ThreadComponents = { Welcome };

/**
 * The chat: one codex thread, live from its channel, rendered by
 * assistant-ui's Thread element through the external-store runtime. The
 * page owns the per-turn model choice and the dirty-tree question.
 */
export function ThreadPage() {
  const { threadId = "" } = useParams();
  const ctx = useOutletContext<ProjectContext>();
  const threads = useThreads(ctx.id);
  const thread = threads.data?.find((th) => th.id === threadId);

  if (threads.isPending) return <Skeleton className="m-4 h-32" data-testid="chat-area" />;
  if (!thread) {
    return (
      <div className="p-4" data-testid="chat-area">
        <Alert variant="destructive">
          <AlertDescription>{t.threadNotFound}</AlertDescription>
        </Alert>
      </div>
    );
  }
  return <ThreadChat key={thread.id} thread={thread} projectId={ctx.id} />;
}

type ThreadRow = { id: string; codexThreadId: string; status: string; modelSlug: string | null };

function ThreadChat({ thread, projectId }: { thread: ThreadRow; projectId: string }) {
  const client = useQueryClient();
  const { view, ready, error } = useThreadView(thread.codexThreadId);
  const [model, setModel] = useState<string | null>(null);
  const [dirty, setDirty] = useState<DirtyPrompt | null>(null);

  const onDirtyTree = useCallback(
    (changes: DirtyChange[]) =>
      new Promise<DirtyDecision>((resolve) => {
        setDirty({
          changes,
          resolve: (decision) => {
            setDirty(null);
            resolve(decision);
          },
        });
      }),
    [],
  );
  const onSent = useCallback(() => {
    client.invalidateQueries({ queryKey: queryKeys.threads(projectId) });
  }, [client, projectId]);

  const disabledReason = t.threadDisabled[thread.status] ?? null;
  const adapter = useMemo(
    () =>
      buildAdapter({
        target: { threadId: thread.id, codexThreadId: thread.codexThreadId },
        view,
        model,
        disabled: !ready || disabledReason !== null,
        onSent,
        onDirtyTree,
      }),
    [thread.id, thread.codexThreadId, view, model, ready, disabledReason, onSent, onDirtyTree],
  );
  const runtime = useExternalStoreRuntime(adapter);

  const state: TurnState = view.requests.length > 0 ? "approval" : runningTurnId(view) ? "running" : "idle";

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="chat-area">
      {error ? (
        <Alert variant="destructive" className="m-3 w-auto">
          <AlertDescription>{t.threadError(error)}</AlertDescription>
        </Alert>
      ) : null}
      {disabledReason ? (
        <Alert className="m-3 w-auto">
          <AlertDescription>{disabledReason}</AlertDescription>
        </Alert>
      ) : null}
      <AssistantRuntimeProvider runtime={runtime} config={chatConfig}>
        <div className="min-h-0 flex-1">
          <Thread components={THREAD_COMPONENTS} autoFocus={false} />
        </div>
        <TurnBar state={state} threadModel={thread.modelSlug} model={model} onModel={setModel} />
      </AssistantRuntimeProvider>
      <DirtyTreeDialog prompt={dirty} />
    </div>
  );
}
