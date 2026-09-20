// `@` in the composer: the project's files from the server's fuzzy index
// (search_files → fuzzyFileSearch), picked into the text as a path — the
// registry's composer-trigger-popover over a live-completion adapter; the
// message shows the path as a chip (directive-text with our formatter).
import { unstable_useLiveCompletionAdapter } from "@assistant-ui/react";
import { FileIcon, FolderIcon, Paperclip, Sparkles } from "lucide-react";
import { searchFiles } from "@/ash_rpc";
import { fileFormatter, fileMentionItems, mentionFormatter } from "@/core/chat/mentions";
import { unwrap } from "@/core/projects";
import { ComposerTriggerPopover } from "@/ui/components/assistant-ui/elements/composer-trigger-popover.aui";
import { createDirectiveText } from "@/ui/components/assistant-ui/elements/directive-text.aui";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

const ICONS = { file: FileIcon, directory: FolderIcon };

/** User message text with `@path` and `$skill` mentions as chips. */
export const FileMentionText = createDirectiveText(mentionFormatter, { iconMap: { ...ICONS, skill: Sparkles, attachment: Paperclip }, fallbackIcon: FileIcon });

export function FileMentions() {
  const { projectId } = useChat();
  const files = unstable_useLiveCompletionAdapter({
    cacheKey: projectId,
    fetcher: async (query) => {
      if (!query) return [];
      const matches = unwrap(await searchFiles({ fields: ["path", "fileName", "matchType"], input: { id: projectId, query } }));
      return fileMentionItems(matches);
    },
  });
  return (
    <ComposerTriggerPopover
      char="@"
      adapter={files.adapter}
      isLoading={files.isLoading}
      directive={{ formatter: fileFormatter }}
      className="w-96 max-w-[calc(100vw-2rem)]"
      iconMap={ICONS}
      fallbackIcon={FileIcon}
      backLabel={t.mentionFiles.back}
      emptyCategoriesLabel={t.mentionFiles.none}
      emptyItemsLabel={t.mentionFiles.empty}
      loadingLabel={t.mentionFiles.loading}
    />
  );
}
