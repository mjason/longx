import { useTranslation } from "react-i18next";
// `@` in the composer: the project's files from the server's fuzzy index
// (search_files → fuzzyFileSearch), picked into the text as a path — the
// registry's composer-trigger-popover over a live-completion adapter; the
// message shows the path as a chip (directive-text with our formatter).
import { unstable_useLiveCompletionAdapter } from "@assistant-ui/react";
import { useQueryClient } from "@tanstack/react-query";
import { Bot, FileIcon, FolderIcon, Paperclip, Sparkles } from "lucide-react";
import { useParams } from "react-router";
import { directory, searchFiles } from "@/core/api";
import { fileMentionItems, mentionFormatter, mentionTriggerMatch, sessionMentionItems } from "@/core/chat/mentions";
import { unwrap, type SessionEntry } from "@/core/projects";
import { ComposerTriggerPopover } from "@/ui/components/assistant-ui/elements/composer-trigger-popover.aui";
import { createDirectiveText } from "@/ui/components/assistant-ui/elements/directive-text.aui";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

const ICONS = { file: FileIcon, directory: FolderIcon, session: Bot };

/** User message text with `@path` and `$skill` mentions as chips. */
export const FileMentionText = createDirectiveText(mentionFormatter, { iconMap: { ...ICONS, skill: Sparkles, attachment: Paperclip }, fallbackIcon: FileIcon });

export function FileMentions() {
    useTranslation();
  const { projectId, thread } = useChat();
  const { slug = "" } = useParams();
  const client = useQueryClient();
  const files = unstable_useLiveCompletionAdapter({
    cacheKey: `${projectId}:${thread?.id ?? ""}:${slug}`,
    fetcher: async (query) => {
      const [sessions, matches] = await Promise.allSettled([
        client.fetchQuery({
          queryKey: ["sessions", projectId, "all"],
          staleTime: 5_000,
          queryFn: async () => unwrap(await directory({ input: { projectId, scope: "all" } })).sessions as SessionEntry[],
        }),
        query ? searchFiles({ input: { id: projectId, query } }).then(unwrap) : Promise.resolve([]),
      ]);
      // One unavailable directory must not break the other kind of completion.
      if (sessions.status === "rejected" && matches.status === "rejected") throw sessions.reason;
      return [
        ...(sessions.status === "fulfilled" ? sessionMentionItems(sessions.value, query, thread?.id, slug, t.mentionFiles.sessionHint) : []),
        ...(matches.status === "fulfilled" ? fileMentionItems(matches.value) : []),
      ];
    },
  });
  return (
    <ComposerTriggerPopover
      char="@"
      matcher={mentionTriggerMatch}
      adapter={files.adapter}
      isLoading={files.isLoading}
      directive={{ formatter: mentionFormatter }}
      className="w-96 max-w-[calc(100vw-2rem)]"
      iconMap={ICONS}
      fallbackIcon={FileIcon}
      backLabel={t.mentionFiles.back}
      emptyCategoriesLabel={t.mentionFiles.sessionSearch}
      emptyItemsLabel={t.mentionFiles.sessionEmpty}
      loadingLabel={t.mentionFiles.loading}
    />
  );
}
