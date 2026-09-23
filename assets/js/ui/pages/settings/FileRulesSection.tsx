// Settings → 文件监控: the global rules every project's file watcher, tree
// and @ search follow, beside the built-in lists they stack on.
import { useState } from "react";
import { toast } from "sonner";
import { useFileRules, useSaveFileRules, type FileRules } from "@/core/fileRules";
import { FileRulesFields } from "@/ui/components/FileRulesFields";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.fileRules;

export function FileRulesSection() {
  const rules = useFileRules();
  const save = useSaveFileRules();
  const [draft, setDraft] = useState<FileRules | null>(null);
  if (rules.isPending) return <Skeleton className="h-40 w-full" />;
  if (rules.isError) return <p className="text-destructive text-sm">{rules.error.message}</p>;
  const value = draft ?? { ignore: rules.data.ignore, watch: rules.data.watch };
  return (
    <div className="flex flex-col gap-4" data-testid="section-files">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <p className="text-muted-foreground text-sm">{s.layers}</p>
      <FileRulesFields idPrefix="fr" value={value} onChange={setDraft} builtin={{ ignore: rules.data.builtinIgnore, watch: rules.data.builtinWatch }} />
      <div>
        <Button
          size="sm"
          disabled={draft === null || save.isPending}
          onClick={() =>
            save.mutate(value, {
              onSuccess: () => {
                toast.success(t.saved);
                setDraft(null);
              },
              onError: (e) => toast.error(e.message),
            })
          }
        >
          {s.save}
        </Button>
      </div>
    </div>
  );
}
