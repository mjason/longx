import { toast } from "sonner";
import { usePromotionPreview, usePromoteLocal } from "@/core/agent";
import { Button } from "@/ui/components/ui/button";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { useSettingsCopy } from "./copy";
import { t } from "@/ui/strings";

export function PromotionDialog({ projectId, path, onClose }: { projectId: string; path: string | null; onClose: () => void }) {
  const s = useSettingsCopy();
  const preview = usePromotionPreview(projectId, path);
  const promote = usePromoteLocal(projectId);
  const confirm = async () => {
    if (!preview.data?.canShare) return;
    try {
      await promote.mutateAsync({ path: preview.data.path, digest: preview.data.digest });
      toast.success(s.shareSaved);
      onClose();
    } catch (error) {
      toast.error((error as Error).message);
      await preview.refetch();
    }
  };
  return (
    <Dialog open={path !== null} onOpenChange={(open) => { if (!open && !promote.isPending) onClose(); }}>
      <DialogContent className="sm:max-w-3xl">
        <DialogHeader><DialogTitle>{s.prepareShare}</DialogTitle><DialogDescription>{s.shareHint}</DialogDescription></DialogHeader>
        <DialogBody className="space-y-4">
          {preview.isPending ? <p>{s.loading}</p> : null}
          {preview.isError ? <p role="alert" className="text-destructive">{preview.error.message}</p> : null}
          {preview.data ? <>
            <p className="break-all font-mono text-xs">{s.target}: {preview.data.target}</p>
            {preview.data.conflicts.length ? <div role="alert" className="text-destructive text-sm"><p>{s.conflict}</p><ul>{preview.data.conflicts.map((f) => <li className="break-all font-mono" key={f}>{f}</li>)}</ul></div> : null}
            <p className="text-warning text-xs">{s.shareWarning}</p>
            {preview.data.files.map((file) => (
              <details key={file.source} className="rounded border p-3">
                <summary className="cursor-pointer break-all font-mono text-xs">{file.source} → {file.target} · {file.size} {s.bytes}</summary>
                {file.content !== null ? <pre className="mt-3 overflow-x-auto whitespace-pre-wrap break-all text-xs">{file.content}</pre> : <p className="text-muted-foreground mt-3 text-xs">{s.noText}</p>}
              </details>
            ))}
          </> : null}
        </DialogBody>
        <DialogFooter>
          <Button variant="outline" disabled={promote.isPending} onClick={onClose}>{t.cancel}</Button>
          <Button disabled={!preview.data?.canShare || preview.isFetching || promote.isPending} onClick={confirm}>{s.confirmShare}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
