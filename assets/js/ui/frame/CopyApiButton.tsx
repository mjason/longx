// The top bar's "复制 API 地址" on a conversation's page: the page's address
// with /api in front — the conversation as JSON (LongxWeb.ApiController) for
// another agent to look into what happened.
import { Braces } from "lucide-react";
import { useParams } from "react-router";
import { toast } from "sonner";
import { copyText } from "@/ui/lib/clipboard";
import { t } from "@/ui/strings";

/** The JSON address of a conversation's page. */
export const apiUrl = (slug: string, threadId: string) => `${window.location.origin}/api/p/${slug}/t/${threadId}`;

export function CopyApiButton({ slug }: { slug: string }) {
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
    <button type="button" aria-label={t.copyApi} title={t.copyApi} onClick={() => void copy()} className="touch-target text-muted-foreground hover:text-foreground flex items-center justify-center rounded-md">
      <Braces className="size-5" />
    </button>
  );
}
