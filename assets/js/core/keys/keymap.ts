// The space menu's tree (Spacemacs' leader, without its modes): outside a
// text field, space opens it and each key walks one level down; a leaf
// names a command. The tree is built from the key table's `SPC …` bindings
// (./bindings, leaderTree), the person's own keys included.

export type KeyNode = {
  /** the key as `KeyboardEvent.key` gives it: "b", "T", ":", " " (space), "Tab" */
  key: string;
  label: string;
  /** a leaf: the command it runs */
  command?: string;
  /** a group: the keys below it */
  children?: KeyNode[];
};

/** The node a sequence of keys reaches (below space), null when none. */
export function lookup(tree: KeyNode[], sequence: string[]): KeyNode | null {
  let nodes = tree;
  let node: KeyNode | null = null;
  for (const key of sequence) {
    node = nodes.find((n) => n.key === key) ?? null;
    if (!node) return null;
    nodes = node.children ?? [];
  }
  return node;
}

const SHOWN: Record<string, string> = { " ": "SPC", Tab: "TAB" };

/** "SPC b d" */
export function formatSequence(sequence: string[]): string {
  return sequence.map((k) => SHOWN[k] ?? k).join(" ");
}

function anyAvailable(node: KeyNode, available: (id: string) => boolean): boolean {
  if (node.command) return available(node.command);
  return (node.children ?? []).some((c) => anyAvailable(c, available));
}

/** The keys below a sequence that can do something now (a group: when anything below it can). */
export function visibleChildren(tree: KeyNode[], sequence: string[], available: (id: string) => boolean): KeyNode[] {
  const nodes = sequence.length === 0 ? tree : (lookup(tree, sequence)?.children ?? []);
  return nodes.filter((n) => anyAvailable(n, available));
}

/** Whether a node can do something now. */
export function nodeAvailable(node: KeyNode, available: (id: string) => boolean): boolean {
  return anyAvailable(node, available);
}
