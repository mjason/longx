import { Thread, type ThreadComponents } from "@/ui/components/assistant-ui/elements/thread.aui";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { Link, useOutletContext } from "react-router";
import { Alert, AlertDescription } from "@/ui/components/ui/alert";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";
import { FileMentions, FileMentionText } from "./FileMentions";
import { ReasoningSteps } from "./ReasoningSteps";
import { SlashCommands } from "./SlashCommands";
import { ComposerLeading, ComposerTrailing } from "./TurnBar";

const Welcome = () => (
  <div className="mb-6 flex flex-col items-center px-4 text-center">
    <h1 className="text-2xl font-medium tracking-tight">{t.welcomeChat}</h1>
    <p className="text-muted-foreground mt-2 text-sm">{t.welcomeChatHint}</p>
  </div>
);

// the composer's trigger popovers: `@` files, `/` commands
const ComposerPopovers = () => (
  <>
    <FileMentions />
    <SlashCommands />
  </>
);

// module scope: a new object per render would remount every message
const THREAD_COMPONENTS: ThreadComponents = { Welcome, ComposerLeading, ComposerTrailing, ComposerPopovers, UserText: FileMentionText, ReasoningGroup: ReasoningSteps };

/**
 * The centre of the project window: assistant-ui's Thread element over the
 * runtime `ChatProvider` mounted — the thread in the route, or a new chat
 * whose first message creates the thread.
 */
export function ThreadPage() {
  const chat = useChat();
  const ctx = useOutletContext<ProjectContext>();

  if (chat.missing) {
    return (
      <div className="p-4" data-testid="chat-area">
        <Alert variant="destructive">
          <AlertDescription>{t.threadNotFound}</AlertDescription>
        </Alert>
        <Button asChild variant="outline" className="mt-3">
          <Link to={`/p/${ctx.slug}`}>{t.newThread}</Link>
        </Button>
      </div>
    );
  }

  const disabled = chat.disabledReason ? t.threadDisabled[chat.disabledReason] : chat.thread?.status === "disconnected" ? t.threadDisabled["disconnected"] : null;

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="chat-area">
      {chat.error ? (
        <Alert variant="destructive" className="m-3 w-auto">
          <AlertDescription>{t.threadError(chat.error)}</AlertDescription>
        </Alert>
      ) : null}
      {disabled ? (
        <Alert className="m-3 w-auto">
          <AlertDescription>{disabled}</AlertDescription>
        </Alert>
      ) : null}
      <div className="min-h-0 flex-1">
        <Thread components={THREAD_COMPONENTS} autoFocus={false} />
      </div>
    </div>
  );
}
