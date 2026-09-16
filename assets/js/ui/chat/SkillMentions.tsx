// `$` in the composer: codex's skills for the project (list_skills →
// skills/list), picked into the text as `$name` — the same
// composer-trigger-popover as the file mentions; on send the adapter puts
// the named SKILL.md files on the turn as skill inputs.
import { unstable_useLiveCompletionAdapter } from "@assistant-ui/react";
import { Sparkles } from "lucide-react";
import { mentionFormatter, skillMentionItems } from "@/core/chat/mentions";
import { useSkills } from "@/core/projects";
import { ComposerTriggerPopover } from "@/ui/components/assistant-ui/elements/composer-trigger-popover.aui";
import { t } from "@/ui/strings";
import { useChat } from "./ChatProvider";

const ICONS = { skill: Sparkles };

export function SkillMentions() {
  const { projectId } = useChat();
  const skills = useSkills(projectId);
  const items = skillMentionItems(skills.data ?? []);
  const completion = unstable_useLiveCompletionAdapter({
    cacheKey: `${projectId}:${items.length}`,
    fetcher: async (query) => {
      const q = query.toLowerCase();
      return items.filter((i) => !q || i.label.toLowerCase().includes(q) || (i.description ?? "").toLowerCase().includes(q));
    },
  });
  return (
    <ComposerTriggerPopover
      char="$"
      adapter={completion.adapter}
      isLoading={completion.isLoading || skills.isPending}
      directive={{ formatter: mentionFormatter }}
      className="w-96 max-w-[calc(100vw-2rem)]"
      iconMap={ICONS}
      fallbackIcon={Sparkles}
      backLabel={t.mentionSkills.back}
      emptyCategoriesLabel={t.mentionSkills.none}
      emptyItemsLabel={t.mentionSkills.empty}
      loadingLabel={t.mentionSkills.loading}
    />
  );
}
