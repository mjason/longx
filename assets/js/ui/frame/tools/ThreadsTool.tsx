import { useChat } from "@/ui/chat/ChatProvider";
import { RunningIdsContext, ThreadWorkContext, ThreadList } from "@/ui/components/assistant-ui/elements/thread-list.aui";
import { useRunningThreads } from "@/core/projects";
import { t } from "@/ui/strings";
import { useTranslation } from "react-i18next";

/** IDEA's Project tree, for us: the project's threads (assistant-ui's ThreadList over the runtime's thread list), every one at work marked. */
export function ThreadsTool() {
  useTranslation();
  const { runningThreadIds } = useChat();
  const running = useRunningThreads();
  const work = new Map((running.data ?? []).filter(row => (row.jobActivity?.total ?? 0) > 0).map(row => [row.id, t.jobWork.states[row.jobActivity!.state]]));
  return (
    <div data-testid="threads-tool">
      <RunningIdsContext.Provider value={runningThreadIds}>
        <ThreadWorkContext.Provider value={work}>
        <ThreadList />
        </ThreadWorkContext.Provider>
      </RunningIdsContext.Provider>
    </div>
  );
}
