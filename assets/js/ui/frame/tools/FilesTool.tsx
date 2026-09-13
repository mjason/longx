import { t } from "@/ui/strings";

export function FilesTool() {
  return <p className="text-muted-foreground text-sm" data-testid="files-tool">{t.filesPending}</p>;
}
