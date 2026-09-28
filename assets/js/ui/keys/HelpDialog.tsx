// SPC ?: every key of the space menu by group, what cannot run now greyed.
import { useCommandsVersion } from "@/core/keys/useCommand";
import { commands } from "@/core/keys/registry";
import { formatSequence, nodeAvailable, SPACE_TREE, type KeyNode } from "@/core/keys/keymap";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { t } from "@/ui/strings";
import { updateKeysUi, useKeysUi } from "./state";

function Row({ sequence, node, keys }: { sequence: string[]; node: KeyNode; keys?: string }) {
  const available = nodeAvailable(node, commands.available);
  return (
    <li className={`flex items-center gap-3 text-sm ${available ? "" : "text-muted-foreground/60"}`}>
      <kbd className="bg-muted min-w-24 shrink-0 rounded px-1.5 py-0.5 font-mono text-xs">{keys ?? formatSequence([" ", ...sequence])}</kbd>
      <span>{node.label}</span>
      {available ? null : <span className="text-xs">（{t.keys.unavailable}）</span>}
    </li>
  );
}

export function HelpDialog() {
  const { help } = useKeysUi();
  useCommandsVersion();
  // the tabs' 1…9 are one row, as in the which-key panel
  const isDigit = (n: KeyNode) => /^[1-9]$/.test(n.key);
  const leaves = SPACE_TREE.filter((n) => n.command && !isDigit(n));
  const firstDigit = SPACE_TREE.find(isDigit);
  const groups = SPACE_TREE.filter((n) => n.children);
  return (
    <Dialog open={help} onOpenChange={(open) => updateKeysUi({ help: open })}>
      <DialogContent className="sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>{t.keys.help}</DialogTitle>
          <DialogDescription>{t.keys.helpHint}</DialogDescription>
        </DialogHeader>
        <DialogBody>
          <ul className="grid gap-1.5 sm:grid-cols-2">
            {leaves.map((n) => (
              <Row key={n.key} sequence={[n.key]} node={n} />
            ))}
            {firstDigit ? <Row sequence={[firstDigit.key]} node={{ ...firstDigit, label: t.keys.tabs }} keys="SPC 1…9" /> : null}
          </ul>
          <div className="mt-4 grid gap-5 sm:grid-cols-2">
            {groups.map((g) => (
              <section key={g.key}>
                <h3 className="mb-1.5 text-sm font-medium">
                  <kbd className="bg-muted mr-2 rounded px-1.5 py-0.5 font-mono text-xs">{formatSequence([" ", g.key])}</kbd>
                  {g.label}
                </h3>
                <ul className="grid gap-1">
                  {(g.children ?? []).map((n) => (
                    <Row key={n.key} sequence={[g.key, n.key]} node={n} />
                  ))}
                </ul>
              </section>
            ))}
          </div>
        </DialogBody>
      </DialogContent>
    </Dialog>
  );
}
