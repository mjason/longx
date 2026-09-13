import { ThreadList } from "@/ui/components/assistant-ui/elements/thread-list.aui";

/** IDEA's Project tree, for us: the project's threads (assistant-ui's ThreadList over the runtime's thread list). */
export function ThreadsTool() {
  return (
    <div data-testid="threads-tool">
      <ThreadList />
    </div>
  );
}
