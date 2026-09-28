// The space menu's key tree (Spacemacs' leader, without its modes): outside
// a text field, space opens it and each key walks one level down; a leaf
// names a command of the registry (./registry). Mnemonic groups, Chinese
// labels — the which-key panel shows them as they are. Plain data: a native
// client (the Tauri menus later) reads the same tree.

export type KeyNode = {
  /** the key as `KeyboardEvent.key` gives it: "b", "T", ":", " " (space), "Tab" */
  key: string;
  label: string;
  /** a leaf: the command it runs */
  command?: string;
  /** a group: the keys below it */
  children?: KeyNode[];
};

const digits: KeyNode[] = Array.from({ length: 9 }, (_, i) => ({
  key: String(i + 1),
  label: `第 ${i + 1} 个标签`,
  command: `tab.goto.${i + 1}`,
}));

export const SPACE_TREE: KeyNode[] = [
  { key: " ", label: "和 AI 对话", command: "ai.focus" },
  { key: ":", label: "命令面板", command: "palette.open" },
  { key: "?", label: "全部快捷键", command: "help.keys" },
  { key: "Tab", label: "上一个标签", command: "tab.last" },
  { key: ",", label: "设置", command: "settings.open" },
  ...digits,
  {
    key: "a",
    label: "对话",
    children: [
      { key: "s", label: "停止这一轮", command: "turn.stop" },
      { key: "r", label: "继续", command: "turn.continue" },
      { key: "d", label: "丢弃这一轮", command: "turn.discard" },
      { key: "n", label: "新会话", command: "thread.new" },
      { key: "c", label: "压缩上下文", command: "thread.compact" },
      { key: "g", label: "目标", command: "goal.open" },
      { key: "m", label: "换模型", command: "model.pick" },
      { key: "e", label: "换档位", command: "effort.pick" },
      { key: "w", label: "立即插入等着的消息", command: "waiting.release" },
      { key: "y", label: "处理等你的请求", command: "ask.open" },
    ],
  },
  {
    key: "t",
    label: "会话",
    children: [
      { key: "t", label: "切换会话", command: "thread.switch" },
      { key: "r", label: "重命名", command: "thread.rename" },
      { key: "a", label: "归档", command: "thread.archive" },
      { key: "s", label: "子 agent", command: "subagents.open" },
    ],
  },
  {
    key: "b",
    label: "标签",
    children: [
      { key: "b", label: "切换标签", command: "tab.switch" },
      { key: "d", label: "关闭标签", command: "tab.close" },
      { key: "u", label: "重开刚关的标签", command: "tab.reopen" },
      { key: "n", label: "下一个标签", command: "tab.next" },
      { key: "p", label: "上一个标签", command: "tab.prev" },
      { key: "c", label: "回到聊天", command: "tab.chat" },
    ],
  },
  {
    key: "f",
    label: "文件",
    children: [
      { key: "f", label: "找文件", command: "file.find" },
      { key: "t", label: "文件树", command: "files.open" },
      { key: "s", label: "保存", command: "file.save" },
      { key: "l", label: "在文件树里定位", command: "file.reveal" },
    ],
  },
  {
    key: "g",
    label: "Git",
    children: [
      { key: "g", label: "Git 窗口", command: "git.open" },
      { key: "c", label: "提交", command: "git.commit" },
      { key: "p", label: "推送", command: "git.push" },
      { key: "f", label: "拉取", command: "git.pull" },
      { key: "l", label: "历史", command: "git.history" },
      { key: "b", label: "分支", command: "git.branches" },
    ],
  },
  {
    key: "w",
    label: "工具窗口",
    children: [
      { key: "1", label: "会话", command: "tool.threads" },
      { key: "2", label: "Git", command: "tool.git" },
      { key: "3", label: "Agents", command: "tool.agents" },
      { key: "4", label: "文件", command: "tool.files" },
      { key: "w", label: "显示 / 隐藏侧栏", command: "tool.toggle" },
      { key: "a", label: "Agents 面板", command: "agents.panel" },
    ],
  },
  {
    key: "p",
    label: "项目",
    children: [
      { key: "p", label: "切换项目", command: "project.switch" },
      { key: "s", label: "项目设置", command: "project.settings" },
      { key: "n", label: "新建项目", command: "project.new" },
    ],
  },
  {
    key: "j",
    label: "跳转",
    children: [
      { key: "j", label: "最新消息", command: "jump.bottom" },
      { key: "a", label: "等你处理的请求", command: "jump.ask" },
      { key: "e", label: "最近的错误", command: "jump.error" },
    ],
  },
  {
    key: "T",
    label: "开关",
    children: [
      { key: "t", label: "深色 / 浅色", command: "toggle.theme" },
      { key: "r", label: "思考过程默认展开", command: "toggle.reasoning" },
    ],
  },
  {
    key: "m",
    label: "当前页面",
    children: [
      { key: "s", label: "保存", command: "editor.save" },
      { key: "v", label: "预览 / 编辑", command: "editor.preview" },
      { key: "n", label: "下一处改动", command: "diff.next" },
      { key: "p", label: "上一处改动", command: "diff.prev" },
    ],
  },
];

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

/** Where a command sits in the tree (below space), null when nowhere. */
export function sequenceOf(tree: KeyNode[], command: string): string[] | null {
  for (const node of tree) {
    if (node.command === command) return [node.key];
    if (node.children) {
      const below = sequenceOf(node.children, command);
      if (below) return [node.key, ...below];
    }
  }
  return null;
}

const SHOWN: Record<string, string> = { " ": "SPC", Tab: "TAB" };

/** "SPC b d" */
export function formatSequence(sequence: string[]): string {
  return sequence.map((k) => SHOWN[k] ?? k).join(" ");
}

/** What the page shows for a command: "SPC b d", or null when it has no keys. */
export function hintOf(command: string, tree: KeyNode[] = SPACE_TREE): string | null {
  const seq = sequenceOf(tree, command);
  return seq ? formatSequence([" ", ...seq]) : null;
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
