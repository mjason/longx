// A download's progress: the stage with the bytes so far, and a bar once
// the total is known — the same line for the upgrade and the browser.
import { Loader2 } from "lucide-react";
import { formatBytes } from "@/core/format";

export function DownloadBar({ label, received, total }: { label: string; received: number; total: number | null }) {
  return (
    <div className="flex flex-col gap-1.5" role="status">
      <p className="flex items-center gap-2 text-sm">
        <Loader2 className="size-4 animate-spin" /> {label}
        <span className="text-muted-foreground font-mono text-xs tabular-nums">
          {formatBytes(received)}
          {total ? ` / ${formatBytes(total)}` : ""}
        </span>
      </p>
      {total ? (
        <div className="bg-muted h-1.5 w-full max-w-md overflow-hidden rounded-full" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={received}>
          <div className="bg-primary h-full transition-[width]" style={{ width: `${Math.min(100, (received / total) * 100)}%` }} />
        </div>
      ) : null}
    </div>
  );
}
