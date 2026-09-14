// `/` in the composer: the commands codex's TUI has, over the registry's
// composer-trigger-popover with the slash-command adapter. Thread commands
// (/review, /compact, /init) go to the backend; the rest open a tool or a
// page. The text clears on pick — a command is not part of the message.
import { unstable_useSlashCommandAdapter, useAui } from "@assistant-ui/react";
import { FolderTree, GitBranch, History, MessageSquarePlus, Minimize2, ScrollText, Search, Settings } from "lucide-react";
import { useMemo } from "react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { compactThread, reviewThread } from "@/ash_rpc";
import { useFrame } from "@/core/frame";
import { unwrap } from "@/core/projects";
import { ComposerTriggerPopover } from "@/ui/components/assistant-ui/elements/composer-trigger-popover.aui";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

const ICONS = { new: MessageSquarePlus, review: Search, compact: Minimize2, init: ScrollText, git: GitBranch, files: FolderTree, history: History, settings: Settings };

export function SlashCommands() {
  const { thread } = useChat();
  const aui = useAui();
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
        id: "review",
        description: t.commands.review,
        icon: "review",
        execute: onThread(async (id) => {
          unwrap(await reviewThread({ fields: ["id"], input: { threadId: id, target: "uncommitted" } }));
          toast.success(t.commands.reviewStarted);
        }),
      },
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
      { id: "git", description: t.commands.git, icon: "git", execute: () => frame.open("git") },
      { id: "files", description: t.commands.files, icon: "files", execute: () => frame.open("files") },
      { id: "history", description: t.commands.history, icon: "history", execute: () => frame.open("history") },
      { id: "settings", description: t.commands.settings, icon: "settings", execute: () => navigate(`/p/${slug}/settings`) },
    ];
  }, [threadId, aui, frame, navigate, slug]);

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
