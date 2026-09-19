// `/` in the composer, over the registry's composer-trigger-popover with
// the slash-command adapter. Thread commands (/compact, /init, /goal) go to
// the backend; the rest open a tool or a page. The text clears on pick — a command is not part of the message.
import { unstable_useSlashCommandAdapter, useAui } from "@assistant-ui/react";
import { FolderTree, GitBranch, MessageSquarePlus, Minimize2, ScrollText, Settings, Target } from "lucide-react";
import { useMemo } from "react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { compactThread } from "@/ash_rpc";
import { useFrame } from "@/core/frame";
import { unwrap } from "@/core/projects";
import { ComposerTriggerPopover } from "@/ui/components/assistant-ui/elements/composer-trigger-popover.aui";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";
import { useGoalDialog } from "./GoalBar";

const ICONS = { new: MessageSquarePlus, compact: Minimize2, init: ScrollText, goal: Target, git: GitBranch, files: FolderTree, settings: Settings };

export function SlashCommands() {
  const { thread } = useChat();
  const aui = useAui();
  const goalDialog = useGoalDialog();
  const frame = useFrame();
  const navigate = useNavigate();
  const { slug } = useParams();
  const threadId = thread?.id;

  const commands = useMemo(() => {
    const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));
    const onThread = (run: (id: string) => Promise<void>) => () => {
      if (!threadId) return void toast.error(t.commands.needsThread);
      void run(threadId).catch(fail);
    };
    return [
      { id: "new", description: t.commands.new, icon: "new", execute: () => navigate(`/p/${slug}`) },
      {
        id: "compact",
        description: t.commands.compact,
        icon: "compact",
        execute: onThread(async (id) => {
          unwrap(await compactThread({ input: { threadId: id } }));
          toast.success(t.commands.compacted);
        }),
      },
      { id: "init", description: t.commands.init, icon: "init", execute: () => aui.thread.append({ role: "user", content: [{ type: "text", text: t.initPrompt }] }) },
      { id: "goal", description: t.commands.goal, icon: "goal", execute: () => goalDialog?.open() },
      { id: "git", description: t.commands.git, icon: "git", execute: () => frame.open("git") },
      { id: "files", description: t.commands.files, icon: "files", execute: () => frame.open("files") },
      { id: "settings", description: t.commands.settings, icon: "settings", execute: () => navigate(`/p/${slug}/settings`) },
    ];
  }, [threadId, aui, frame, navigate, slug, goalDialog]);

  const slash = unstable_useSlashCommandAdapter({ commands, removeOnExecute: true, iconMap: ICONS });
  return (
    <ComposerTriggerPopover
      char="/"
      adapter={slash.adapter}
      action={{ onExecute: slash.action.onExecute, removeOnExecute: slash.action.removeOnExecute }}
      className="w-96 max-w-[calc(100vw-2rem)]"
      iconMap={ICONS}
      backLabel={t.commands.back}
      emptyCategoriesLabel={t.commands.empty}
      emptyItemsLabel={t.commands.empty}
    />
  );
}
