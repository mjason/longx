import { useOutletContext, useParams } from "react-router";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { Logo } from "@/ui/components/Logo";
import { t } from "@/ui/strings";

/** The centre of the project window until the chat lands (branch ②b). */
export function ChatPlaceholder() {
  const { threadId } = useParams();
  const ctx = useOutletContext<ProjectContext>();
  return (
    <div className="text-muted-foreground flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center" data-testid="chat-area">
      <Logo size={56} className="opacity-40 grayscale" />
      <p className="text-sm">{threadId ? t.threadPagePending : t.pickThread}</p>
      <p className="font-mono text-xs opacity-60">{ctx.rootPath}</p>
    </div>
  );
}
