// One open file: CodeMirror over the file's content, a draft while typing,
// save with the button or ⌘S. Binary or over-large files are shown as
// such rather than mangled; a phone wraps lines.
import { Save, Undo2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useViewport } from "@/core/viewport";
import { useWorkbench } from "@/core/workbench";
import { useFileContent, useSaveFile } from "@/core/workspace";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { CodeEditor } from "@/ui/editor/CodeEditor";
import { t } from "@/ui/strings";

export function EditorTab({ projectId, path }: { projectId: string; path: string }) {
  const file = useFileContent(projectId, path);
  const save = useSaveFile(projectId);
  const workbench = useWorkbench(projectId);
  const viewport = useViewport();
  const key = `file:${path}`;
  // null = showing what is on disk; a string = the draft being edited
  const [draft, setDraft] = useState<string | null>(null);
  const dirty = draft !== null && draft !== file.data?.content;

  useEffect(() => {
    workbench.markDirty(key, dirty);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dirty, key]);

  // the file changed on disk (a turn, a pull) while no edit is pending: show the new one
  useEffect(() => {
    if (!dirty) setDraft(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [file.data?.content]);

  const doSave = () => {
    if (!dirty || draft === null) return;
    save.mutate(
      { path, content: draft },
      {
        onSuccess: () => {
          setDraft(null);
          toast.success(t.savedFile);
        },
        onError: (error) => toast.error(error.message),
      },
    );
  };

  if (file.isPending) return <Skeleton className="m-4 h-32" />;
  if (file.isError) return <p className="text-destructive p-4 text-sm">{t.fileLoadFailed(file.error.message)}</p>;
  if (file.data.binary) return <p className="text-muted-foreground p-4 text-sm">{t.binaryFile}</p>;
  const readOnly = file.data.truncated;

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="editor-tab">
      <div className="bg-sidebar border-sidebar-border flex h-9 shrink-0 items-center gap-2 border-b px-3 text-xs">
        <span className="text-muted-foreground min-w-0 flex-1 truncate font-mono">{path}</span>
        {readOnly ? <span className="text-warning">{t.truncatedFile(Math.round(file.data.size / 1024))}</span> : null}
        {dirty ? (
          <>
            <span className="text-warning">●</span>
            <Button variant="ghost" size="sm" className="h-7 px-2" onClick={() => setDraft(null)}>
              <Undo2 /> {t.discardEdits}
            </Button>
          </>
        ) : null}
        <Button size="sm" className="h-7 px-2" disabled={!dirty || save.isPending} onClick={doSave} data-testid="save-file">
          <Save /> {save.isPending ? t.saving : t.saveFile}
        </Button>
      </div>
      <div className="min-h-0 flex-1 overflow-hidden">
        <CodeEditor path={path} value={draft ?? file.data.content ?? ""} onChange={setDraft} onSave={doSave} readOnly={readOnly} wrap={viewport === "phone"} className="h-full" />
      </div>
    </div>
  );
}
