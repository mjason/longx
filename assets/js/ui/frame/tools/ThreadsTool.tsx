import { useChat } from "@/ui/chat/ChatProvider";
import { RunningIdsContext, ThreadList } from "@/ui/components/assistant-ui/elements/thread-list.aui";

/** IDEA's Project tree, for us: the project's threads (assistant-ui's ThreadList over the runtime's thread list), every one at work marked. */
export function ThreadsTool() {
  const { runningThreadIds } = useChat();
  return (
    <div data-testid="threads-tool">
      <RunningIdsContext.Provider value={runningThreadIds}>
        <ThreadList />
      </RunningIdsContext.Provider>
    </div>
  );
}
