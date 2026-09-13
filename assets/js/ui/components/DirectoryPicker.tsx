import { ChevronRight, CornerLeftUp, Folder, FolderGit2, FolderPlus } from "lucide-react";
import { useEffect, useState } from "react";
import { useCreateDirectory, useDirectory } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Checkbox } from "@/ui/components/ui/checkbox";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

/**
 * IDEA's "Location" dialog, on the server's file system: breadcrumbs,
 * roots to jump to, a list of subdirectories (repositories marked), a hidden
 * toggle and a typed path for those who know where they are going.
 */
export function DirectoryPicker({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (path: string, git: boolean) => void;
}) {
  const [showHidden, setShowHidden] = useState(false);
  const [typed, setTyped] = useState("");
  const [naming, setNaming] = useState<string | null>(null);
  const listing = useDirectory(value, showHidden);
  const create = useCreateDirectory();
  const here = value ?? listing.data?.path ?? null;

  const makeDirectory = async () => {
    const name = naming?.trim();
    if (!name || !here) return;
    const made = await create.mutateAsync({ parent: here, name });
    setNaming(null);
    onChange(made.path, made.git);
  };

  // no choice yet: the server's home is where we are, so that is the choice
  useEffect(() => {
    if (value == null && listing.data) onChange(listing.data.path, listing.data.git);
  }, [value, listing.data, onChange]);

  const crumbs = segments(value ?? listing.data?.path ?? "");

  return (
    <div className="flex flex-col gap-3" data-testid="directory-picker">
      <nav aria-label="路径" className="flex flex-wrap items-center gap-1 text-sm">
        <button type="button" className="touch-target text-muted-foreground hover:text-foreground rounded px-1" onClick={() => onChange("/", false)}>
          /
        </button>
        {crumbs.map((c) => (
          <span key={c.path} className="flex items-center gap-1">
            <ChevronRight className="text-muted-foreground size-3" />
            <button type="button" className="touch-target hover:text-foreground rounded px-1 font-mono" onClick={() => onChange(c.path, false)}>
              {c.name}
            </button>
          </span>
        ))}
      </nav>

      {listing.data?.roots?.length ? (
        <div className="flex flex-wrap gap-2">
          {listing.data.roots.map((r) => (
            <Button key={r.path} type="button" variant="secondary" size="sm" onClick={() => onChange(r.path, r.git)}>
              {r.path === "/" ? "/" : r.name}
            </Button>
          ))}
        </div>
      ) : null}

      <ul className="max-h-[50dvh] divide-y overflow-y-auto rounded-lg border" data-testid="directory-entries" aria-busy={listing.isPending}>
        {listing.data?.parent != null ? (
          <li>
            <button type="button" className="touch-target hover:bg-accent/40 flex w-full items-center gap-3 px-3 py-2 text-left text-sm" onClick={() => onChange(listing.data!.parent!, false)}>
              <CornerLeftUp className="text-muted-foreground size-4" /> {t.parent}
            </button>
          </li>
        ) : null}
        {listing.isPending && !listing.data ? (
          <li className="p-3"><Skeleton className="h-5 w-1/2" /></li>
        ) : listing.isError ? (
          <li role="alert" className="text-destructive p-3 text-sm">{listing.error.message}</li>
        ) : listing.data?.entries.length === 0 ? (
          <li className="text-muted-foreground p-3 text-sm">{t.emptyDirectory}</li>
        ) : (
          listing.data?.entries.map((e) => (
            <li key={e.path}>
              <button
                type="button"
                className="touch-target hover:bg-accent/40 flex w-full items-center gap-3 px-3 py-2 text-left text-sm"
                onClick={() => onChange(e.path, e.git)}
              >
                {e.git ? <FolderGit2 className="text-primary size-4 shrink-0" /> : <Folder className="text-muted-foreground size-4 shrink-0" />}
                <span className="min-w-0 flex-1 truncate font-mono">{e.name}</span>
                {e.git ? <span className="text-primary text-xs">{t.gitRepo}</span> : null}
              </button>
            </li>
          ))
        )}
      </ul>

      <div className="flex flex-wrap items-center gap-4">
        <label className="flex items-center gap-2 text-sm">
          <Checkbox checked={showHidden} onCheckedChange={(v) => setShowHidden(v === true)} /> {t.showHidden}
        </label>
        {naming === null ? (
          <Button type="button" variant="ghost" size="sm" onClick={() => setNaming("")} disabled={!here}>
            <FolderPlus /> {t.newDirectory}
          </Button>
        ) : (
          <form
            className="flex items-center gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              void makeDirectory().catch(() => {});
            }}
          >
            <Label htmlFor="new-directory" className="sr-only">{t.directoryName}</Label>
            <Input id="new-directory" value={naming} onChange={(e) => setNaming(e.target.value)} placeholder={t.directoryName} className="h-9 w-48 font-mono" autoFocus autoCapitalize="none" spellCheck={false} />
            <Button type="submit" size="sm" disabled={!naming.trim() || create.isPending}>{t.create}</Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setNaming(null)}>{t.cancel}</Button>
          </form>
        )}
      </div>
      {create.isError ? <p role="alert" className="text-destructive text-sm">{create.error.message}</p> : null}

      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          if (typed.trim()) onChange(typed.trim(), false);
        }}
      >
        <Label htmlFor="typed-path" className="sr-only">{t.typePath}</Label>
        <Input id="typed-path" value={typed} onChange={(e) => setTyped(e.target.value)} placeholder={t.typePath} className="h-11 font-mono" autoCapitalize="none" spellCheck={false} />
        <Button type="submit" variant="secondary" className="h-11">{t.go}</Button>
      </form>
    </div>
  );
}

function segments(path: string): { name: string; path: string }[] {
  const parts = path.split("/").filter(Boolean);
  return parts.map((name, i) => ({ name, path: "/" + parts.slice(0, i + 1).join("/") }));
}
