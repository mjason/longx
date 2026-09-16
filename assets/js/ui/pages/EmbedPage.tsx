import { useEffect } from "react";
import { useParams, useSearchParams } from "react-router";
import { applyTheme } from "@/core/theme";
import { DiffTab } from "@/ui/workbench/DiffTab";
import { EditorTab } from "@/ui/workbench/EditorTab";

/**
 * A piece of the web client alone on a page, for the phone app's WebView:
 * `/embed/editor/:projectId?path=` (CodeMirror — there is no React Native
 * CodeMirror) and `/embed/diff/:projectId?path=&sha=`. No frame, no bars;
 * `<html data-embed>` names which, for the CSS to size it to the viewport.
 */
export function EmbedPage({ kind }: { kind: "editor" | "diff" }) {
  const { projectId = "" } = useParams();
  const [params] = useSearchParams();
  const path = params.get("path") ?? "";
  const sha = params.get("sha");
  useEffect(() => {
    applyTheme();
    document.documentElement.setAttribute("data-embed", kind);
    return () => document.documentElement.removeAttribute("data-embed");
  }, [kind]);
  return (
    <div className="bg-background flex h-dvh flex-col" data-testid="embed">
      {kind === "editor" ? <EditorTab projectId={projectId} path={path} /> : <DiffTab projectId={projectId} path={path} sha={sha} />}
    </div>
  );
}
