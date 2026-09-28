// The picker the space menu's choosing commands open (core/keys/picker): a
// fixed list filtered as typed, or a search asked as typed (files).
import { useEffect, useState } from "react";
import { closePicker, usePicker, type PickerItem } from "@/core/keys/picker";
import { Command, CommandEmpty, CommandInput, CommandItem, CommandList } from "@/ui/components/ui/command";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { t } from "@/ui/strings";

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
            {items.map((item) => (
              <CommandItem key={item.id} value={`${item.label} ${item.keywords ?? ""} ${item.id}`} onSelect={() => pick(item)}>
                <span className="truncate">{item.label}</span>
                {item.detail ? <span className="text-muted-foreground ml-auto truncate pl-3 font-mono text-xs">{item.detail}</span> : null}
              </CommandItem>
            ))}
          </CommandList>
        </Command>
      </DialogContent>
    </Dialog>
  );
}
