import { MessagesSquare } from "lucide-react";
import { useOutletContext, useParams } from "react-router";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { t } from "@/ui/strings";

/** The centre of the project window until the chat lands (branch ②b). */
export function ChatPlaceholder() {
  const { threadId } = useParams();
  const ctx = useOutletContext<ProjectContext>();
  return (
    <div className="text-muted-foreground flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center" data-testid="chat-area">
      <MessagesSquare className="size-10 opacity-50" />
      <p className="text-sm">{threadId ? t.threadPagePending : t.pickThread}</p>
      <p className="font-mono text-xs opacity-60">{ctx.rootPath}</p>
    </div>
  );
}
