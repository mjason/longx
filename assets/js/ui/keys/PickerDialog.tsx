// The picker the space menu's choosing commands open (core/keys/picker): a
// fixed list filtered as typed, or a search asked as typed (files).
import { useEffect, useState } from "react";
import { closePicker, usePicker, type PickerItem } from "@/core/keys/picker";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/ui/components/ui/command";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { t } from "@/ui/strings";
import { shellCanRenderSurface, shellSurface } from "@/ui/shell/longxShell";

export function PickerDialog() {
  const request = usePicker();
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<PickerItem[] | null>(null);
  const search = request?.search;

  useEffect(() => {
    setQuery("");
    setFound(null);
  }, [request]);

  useEffect(() => {
    if (!request || request.search || !shellCanRenderSurface()) return;
    let live = true;
    void shellSurface({
      surface: "picker",
      title: request.title,
      placement: "bottom",
      data: { placeholder: request.placeholder, items: request.items ?? [] },
    }).then((result) => {
      if (!live) return;
      if (result === null) { closePicker(); return; }
      const id = typeof result === "string" ? result : (result as { id?: unknown })?.id;
      const item = request.items?.find((candidate) => candidate.id === id);
      closePicker();
      if (item) request.onPick(item);
    });
    return () => { live = false; };
  }, [request]);

  useEffect(() => {
    if (!search) return;
    let live = true;
    const timer = setTimeout(() => {
      void search(query).then((items) => live && setFound(items), () => live && setFound([]));
    }, 150);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [search, query]);

  const items = search ? (found ?? []) : (request?.items ?? []);
  if (request && !request.search && shellCanRenderSurface()) return null;
  const pick = (item: PickerItem) => {
    const onPick = request?.onPick;
    closePicker();
    onPick?.(item);
  };

  return (
    <Dialog open={request !== null} onOpenChange={(open) => (open ? null : closePicker())}>
      <DialogContent className="overflow-hidden p-0" showCloseButton={false}>
        <DialogHeader className="sr-only">
          <DialogTitle>{request?.title ?? ""}</DialogTitle>
          <DialogDescription>{request?.placeholder ?? request?.title ?? ""}</DialogDescription>
        </DialogHeader>
        <Command shouldFilter={!search} className="[&_[cmdk-input]]:h-12 [&_[cmdk-item]]:px-2 [&_[cmdk-item]]:py-2.5">
          <CommandInput placeholder={request?.placeholder ?? request?.title} value={query} onValueChange={setQuery} />
          <CommandList>
            <CommandEmpty>{search && found === null ? t.keys.searching : t.keys.noPicked}</CommandEmpty>
            {groups(items).map(([group, members]) =>
              group === null ? (
                members.map(row)
              ) : (
                <CommandGroup key={group} heading={group}>
                  {members.map(row)}
                </CommandGroup>
              ),
            )}
          </CommandList>
        </Command>
      </DialogContent>
    </Dialog>
  );

  function row(item: PickerItem) {
    return (
              <CommandItem key={item.id} value={`${item.label} ${item.keywords ?? ""} ${item.id}`} onSelect={() => pick(item)} data-current={item.current ? "true" : undefined}>
                {item.current ? <span className="text-muted-foreground shrink-0 text-xs">{t.keys.current}</span> : null}
                <span className="truncate">{item.label}</span>
                {item.note ? <span className="text-muted-foreground shrink-0 truncate text-xs">{item.note}</span> : null}
                {item.detail ? <span className="text-muted-foreground ml-auto truncate pl-3 font-mono text-xs">{item.detail}</span> : null}
                {item.hint ? (
                  <span
                    className={`${item.detail ? "ml-3" : "ml-auto"} shrink-0 truncate pl-3 text-xs ${item.tone === "waiting" ? "text-warning" : item.tone === "running" ? "text-primary" : "text-muted-foreground"}`}
                    data-tone={item.tone}
                  >
                    {item.hint}
                  </span>
                ) : null}
              </CommandItem>
    );
  }
}

// the items under their headings, in the order the headings first appear; the ungrouped first
function groups(items: PickerItem[]): [string | null, PickerItem[]][] {
  const out = new Map<string | null, PickerItem[]>();
  for (const item of [...items.filter((i) => !i.group), ...items.filter((i) => i.group)]) {
    const key = item.group ?? null;
    out.set(key, [...(out.get(key) ?? []), item]);
  }
  return [...out.entries()];
}
