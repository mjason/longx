// Copy a conversation's JSON API address for another agent to inspect.
import { Braces } from "lucide-react";
import { useParams } from "react-router";
import { toast } from "sonner";
import { copyText } from "@/ui/lib/clipboard";
import { t } from "@/ui/strings";

/** The JSON address of a conversation's page. */
export const apiUrl = (slug: string, threadId: string) => `${window.location.origin}/api/p/${slug}/t/${threadId}`;

export function CopyApiButton({ slug, compact = false }: { slug: string; compact?: boolean }) {
  const { threadId } = useParams();
  if (!threadId) return null;
  const copy = async () => {
    const url = apiUrl(slug, threadId);
    try {
      await copyText(url);
      toast.success(t.apiCopied, { description: url });
    } catch {
      toast.error(t.apiCopyFailed, { description: url });
    }
  };
  return (
    <button type="button" aria-label={t.copyApi} title={t.copyApi} onClick={() => void copy()} className={`${compact ? "h-6 w-6" : "touch-target"} text-muted-foreground hover:text-foreground flex items-center justify-center rounded-md`}>
      <Braces className={compact ? "size-3" : "size-5"} />
    </button>
  );
}
