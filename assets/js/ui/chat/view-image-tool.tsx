import { useContext, useState } from "react";
import { useTranslation } from "react-i18next";
import { ImageIcon, Loader2 } from "lucide-react";
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { ImageZoom } from "@/ui/components/assistant-ui/elements/image";
import { t } from "@/ui/strings";
import { formatBytes } from "@/core/format";
import { mono } from "@/ui/components/assistant-ui/elements/surfaces";
import { cn } from "@/lib/utils";
import { SurfaceContext, fileUrl } from "./toolkit";

export type ViewImageResult = {
  success?: boolean;
  contentItems?: { text?: string }[];
  details?: { name?: string; path?: string; bytes?: number; mime?: string; attachment?: boolean; error?: string };
};

/** Namespaced view_image calls, including historical calls without a preview.
 * The UI never tries to resolve the tool's arbitrary local argument as a URL. */
const ViewImageTool: ToolCallMessagePartComponent<{ path?: string }, ViewImageResult> = (p) => {
  useTranslation();
  const surface = useContext(SurfaceContext);
  const details = p.result?.details;
  const name = details?.name || p.args.path?.split(/[\\/]/).at(-1) || "";
  const running = p.status.type === "running";
  const failed = p.isError === true || p.status.type === "incomplete" || p.result?.success === false;
  const [loadFailed, setLoadFailed] = useState<string | null>(null);
  const path = details?.path;
  // Only attachment snapshots from the tool's metadata are previewed.
  const href = !failed && surface && path && details?.attachment === true && details?.mime?.startsWith("image/")
    ? fileUrl(surface.projectId, path, true, true) : null;
  const error = details?.error === "not_found" ? t.imageNotFound
    : details?.error === "unsupported_image" ? t.imageUnsupported
    : details?.error === "too_large" ? t.imageTooLarge
    : p.result?.contentItems?.map(item => item.text || "").join("\n");

  return (
    <div className="border-border/60 my-2 flex w-full max-w-md flex-col gap-2 rounded-xl border p-3 text-xs" data-testid="tool-view-image">
      <div className="flex min-w-0 items-center gap-2">
        <ImageIcon className="text-muted-foreground size-3.5 shrink-0" />
        <span className={failed ? "text-destructive shrink-0" : "text-muted-foreground shrink-0"}>
          {running ? t.viewingImage : failed ? t.viewImageFailed : t.viewedImage}
        </span>
        <span className={cn(mono, "min-w-0 flex-1 truncate")} title={p.args.path}>{name}</span>
        {typeof details?.bytes === "number" ? <span className="text-muted-foreground shrink-0">{formatBytes(details.bytes)}</span> : null}
        {running ? <Loader2 className="size-3.5 shrink-0 animate-spin" /> : null}
      </div>
      {!running && (failed ? (
        error ? <p className="text-destructive break-words whitespace-pre-wrap">{error}</p> : null
      ) : href && loadFailed !== href ? (
        <ImageZoom src={href} alt={name}>
          <img src={href} alt={name} loading="lazy" onError={() => setLoadFailed(href)} className="max-h-72 max-w-full rounded-md object-contain" />
        </ImageZoom>
      ) : (
        <p className="text-muted-foreground">{href ? t.imagePreviewLoadFailed : t.imagePreviewUnavailable}</p>
      ))}
    </div>
  );
};

export default ViewImageTool;
