// The which-key panel: what the next key can do, right away and in Chinese
// (Spacemacs' which-key). A group ends in "+"; only what can run now is
// listed; the tabs' 1…9 are one row.
import { useCommandsVersion } from "@/core/keys/useCommand";
import { commands } from "@/core/keys/registry";
import { formatSequence, SPACE_TREE, visibleChildren, type KeyNode } from "@/core/keys/keymap";
import { t } from "@/ui/strings";

type Entry = { key: string; label: string; group: boolean };

function entries(nodes: KeyNode[], top: boolean): Entry[] {
  const out: Entry[] = [];
  const digits = top ? nodes.filter((n) => /^[1-9]$/.test(n.key)) : [];
  for (const node of nodes) {
    if (digits.includes(node)) {
      if (node === digits[0]) out.push({ key: digits.length > 1 ? `1…${digits.length}` : node.key, label: t.keys.tabs, group: false });
      continue;
    }
    out.push({ key: formatSequence([node.key]), label: node.label, group: node.children !== undefined });
  }
  return out;
}

export function WhichKey({ sequence, flash }: { sequence: string[]; flash: number }) {
  useCommandsVersion();
  const nodes = visibleChildren(SPACE_TREE, sequence, commands.available);
  return (
    <div
      data-testid="which-key"
      aria-label={t.keys.menu}
      aria-live="polite"
      className="bg-popover text-popover-foreground fixed inset-x-0 bottom-0 z-50 border-t shadow-2xl"
    >
      <div className="border-border/60 flex items-center gap-3 border-b px-4 py-1.5 text-xs">
        <kbd key={flash} className={`bg-muted rounded px-1.5 py-0.5 font-mono ${flash > 0 ? "animate-[pulse_0.4s_ease-in-out]" : ""}`} data-flash={flash}>
          {formatSequence([" ", ...sequence])}
        </kbd>
        <span className="text-muted-foreground">{t.keys.menuHint}</span>
      </div>
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 px-4 py-3 text-sm sm:grid-cols-3 lg:grid-cols-4">
        {entries(nodes, sequence.length === 0).map((e) => (
          <div key={e.key} className="flex min-w-0 items-center gap-2">
            <kbd className="bg-muted text-foreground min-w-7 shrink-0 rounded px-1.5 py-0.5 text-center font-mono text-xs">{e.key}</kbd>
            <span className={`truncate ${e.group ? "text-primary" : ""}`}>{e.group ? `+${e.label}` : e.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
