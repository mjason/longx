// Every command the keys can run, by id, with the name the page shows for it
// (the which-key panel, SPC ?, the palette, Settings → 快捷键) — a command
// has a name whether or not a key is bound to it. What a command does, and
// whether it can run now, is registered by the part of the page that owns
// its state (./registry, useCommand). The space menu's groups are named here
// too: the second key of `SPC a s` is under 对话.

export const GROUPS: Record<string, string> = {
  a: "对话",
  t: "会话",
  b: "标签",
  f: "文件",
  g: "Git",
  w: "工具窗口",
  p: "项目",
  j: "跳转",
  T: "开关",
  m: "当前页面",
};

const TABS = Object.fromEntries(Array.from({ length: 9 }, (_, i) => [`tab.goto.${i + 1}`, `第 ${i + 1} 个标签`]));

export const COMMANDS: Record<string, string> = {
  "ai.focus": "和 AI 对话",
  "palette.open": "命令面板",
  "help.keys": "全部快捷键",
  "settings.open": "设置",
  // the conversation
  "turn.stop": "停止这一轮",
  "turn.continue": "继续",
  "turn.discard": "丢弃这一轮",
  "thread.new": "新会话",
  "thread.compact": "压缩上下文",
  "goal.open": "目标",
  "model.pick": "换模型",
  "effort.pick": "换档位",
  "waiting.release": "立即插入等着的消息",
  "ask.open": "处理等你的请求",
  // conversations
  "thread.switch": "切换会话",
  "thread.last": "回到上一个会话",
  "thread.next": "下一个会话",
  "thread.prev": "上一个会话",
  "thread.waiting": "下一个等你处理的会话",
  "thread.running": "正在跑的会话",
  "thread.rename": "重命名",
  "thread.archive": "归档",
  "subagents.open": "子 agent",
  // tabs
  "tab.switch": "切换标签",
  "tab.close": "关闭标签",
  "tab.reopen": "重开刚关的标签",
  "tab.next": "下一个标签",
  "tab.prev": "上一个标签",
  "tab.last": "上一次的标签",
  "tab.recent": "按最近使用切换标签",
  "tab.recentBack": "按最近使用反向切换标签",
  "tab.chat": "回到聊天",
  ...TABS,
  // files
  "file.find": "找文件",
  "files.open": "文件树",
  "file.save": "保存",
  "file.reveal": "在文件树里定位",
  // git
  "git.open": "Git 窗口",
  "git.commit": "提交",
  "git.push": "推送",
  "git.pull": "拉取",
  "git.history": "历史",
  "git.branches": "分支",
  // tool windows
  "tool.threads": "会话窗口",
  "tool.git": "Git 窗口开关",
  "tool.agents": "Agents 窗口",
  "tool.files": "文件窗口",
  "tool.toggle": "显示 / 隐藏侧栏",
  "agents.panel": "Agents 面板",
  // the project
  "project.switch": "切换项目",
  "project.settings": "项目设置",
  "project.new": "新建项目",
  // jumps
  "jump.bottom": "最新消息",
  "jump.ask": "等你处理的请求",
  "jump.error": "最近的错误",
  // toggles
  "toggle.theme": "深色 / 浅色",
  "toggle.reasoning": "思考过程默认展开",
  // the tab on screen
  "editor.preview": "预览 / 编辑",
  "diff.next": "下一处改动",
  "diff.prev": "上一处改动",
};

export function commandTitle(id: string): string {
  return COMMANDS[id] ?? id;
}
