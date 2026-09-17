# 原生内核：下一步的设计（已定，四个切片 2026-09-17 全部做完）

2026-09-17 讨论定下来的形状。原则不变：内核只有原子能力，策略全是 `.longx` 里动态加载的代码；
agent loop 就是 OTP 递归；agent 之间用 mailbox；配置在后台配。

## 1. 声明式 agent：先声明，再启动

- 每个 agent 是一份声明（和 `agent.exs` 同一个 `Longx.Agent.Config` 格式）：模型、档位、prompt
  （长的放 `prompt.md`，声明里 `prompt_file`）、管道、以及 `agents [...]`——它**能派谁**。
- 主 agent 是 `.longx/agent.exs`；其余在 `agents/<name>/agent.exs`，一个 agent 一个目录，目录里
  可以有只属于它的 `plugs/` 和 `knowledge/`（always / 索引只对它生效）。
- ~~出厂带几份通用声明当起步包~~ → 改为：出厂不带任何角色。没有声明时 `spawn_agent` 不出现，prompt 教模型在
  `local/agents/<name>/` 里声明一个（下一步生效）；用顺了人提升进 `shared/`。角色是项目里长出来的。
- 模型选"派哪个角色"，不再临时拼模型和参数；审核模型就是 `reviewer` 这份声明。

## 2. 子 agent = 另一个 `Longx.Agent` 进程，交流 = `send`

- 工具只有三个：`spawn_agent(name, task)`、`send_message(agent, text)`、`close_agent(agent)`。
  prompt 里列出这个 agent 可以派的名字和各自的一句摘要。
- `spawn` = 按声明 `Agent.ensure(parent: 我)` + `Agent.send(task)`，立刻返回；孩子在自己的进程里
  跑同一套递归循环。
- **没有 wait**：孩子的最终回答是父 mailbox 里的一条消息（带 `from`）——父在跑就下一步折入上下文
  （和插话同一条路），父空闲就被叫醒开一轮（一个 `record_external_turn` 式的 Turn 行）。孩子也能
  中途主动汇报，父也能中途 `send` 改任务。
- 父 monitor 子：异常退出变成一条"X 崩了"的消息进上下文，`:normal` 不算事。子 monitor 父：父进程没了
  自己收尾退出。不 link，不 trap_exit。
- 上下文里孩子的话是用户消息，前面标 `[agent researcher]`（Responses API 没有 agent role；codex 的
  `agent_message` 只有 OpenAI 认）。transcript 的 item 记 `from`，UI 是带来源标签的气泡。
- **进程很轻，闲了自退，按需重启**：GenServer 超时到期 `{:stop, :normal}`（可先 hibernate），
  `restart: :transient` 不拉回；`send_message` 发现进程不在就按同一 thread id、同一声明 `ensure` 再发。
  状态全在 transcript 里，重启毫秒级。根 agent 一视同仁——这就是 codex Recycler 在 OTP 里的样子。
- 限制：`agents [...]` 本身是权限；深度和同时存活数**后台配**，出厂宽松，代码里只写"必须有上限"。
- 不做：codex 那套 spawn / wait / close + agentsStates 状态机、共享收件箱、跨项目派出。

## 3. 策略是 plug，递归的结束由主模型判断

- 内核原子能力：一步模型调用、工具 task、`halt` / `continue` / `compact` effect、`step.model` /
  `step.effort`、**新增** `{:spawn, name, task}` effect、带 `from` 的 `send`、孩子的报告 / 崩溃进
  mailbox、空闲父被叫醒、**`step.state`**（本轮内跨阶段跨步保留的 map，策略要数轮次用）。
- `:turn_end` 的策略 plug 决定 `continue` 还是结束；判断权可以在主模型（把"达成了就回 DONE"递回去），
  也可以派 `reviewer` 审核后再定。codex 的 Guardian、goal mode、multi-agent 在这里都是几十行 plug。
- 出厂 `Plugs.Agents`（三个工具 + 上限）和 `Plugs.Goal`（`/goal`、`set_goal`、上面的递归策略）。
- 守住的线：`.longx` 里写的是**策略**，plug 仍是纯函数；起 agent、调模型、跑工具都经 effect 由内核执行。
  能自己阻塞着等的代码会让插话和停止进不来——mailbox 把等待变成消息就是为了不要这种代码。

## 4. 目录：两级，`shared/` 与 `local/`

```
.longx/
  agent.exs            # 共同的声明，进 git
  shared/              # 进 git：审过的、给团队的
    agents/  plugs/  knowledge/
  local/               # .gitignore：这台机器、这个人、agent 的草稿
    agent.exs          # 可选：本地覆盖（比如换个模型）
    agents/  plugs/  knowledge/
```

- 层叠：出厂 → 全局（`<data>/agent/`，本来就私有）→ 项目 `shared/` → 项目 `local/` → 某个 agent 自己的目录。
- 写入默认落 `local`；进 `shared` 要明写路径，prompt 说明"共享的是审过的"。索引每条标 shared / local。
- 提升是一个动作：设置页里把一篇 local 的知识 / 一个 plug 移到 shared；`knowledge_promote` 默认不给 agent。
- `plugs/<domain>/*.exs`、`knowledge/<topic>/*.md` 都是两级：写知识必须给主题（顶层文件拒绝），主题目录
  可有 `README.md` 做摘要；索引按主题折叠一行（名字、摘要、篇数），`knowledge_read("project/deploy")`
  列主题下的文档。改现有文档优先于新建。
- Longx 初始化 `.longx` 时自动把 `.longx/local/` 加进 `.gitignore`。信任开关照旧管 shared 的代码。

## 5. 后台配置 = 最上面一层描述

设置页"Agent 内核"一节（全局）+ 项目设置里的覆盖：深度上限、同时存活数、空闲退出时长、默认子 agent
模型 / 档位、默认审核模型。存数据库，加载器把它们变成 `options Agents, …` 等叠在项目描述之上——
和 `agent.exs` 一个格式，只是来源是 UI。全局的 `agents/`、`plugs/`、`knowledge/` 也能在后台直接编辑。

## 切片顺序

1. ✅ 内核原子能力：`spawn` effect、`from` 消息、报告 / 崩溃进 mailbox、空闲父被叫醒、`step.state`、
   闲置自退与按需重启（`Longx.Agent.spawn/4`、`Step.spawn/4`、`send(from:)`、`Specs` + `ensure_alive`、
   `Projects.spawn_native_agent/4` 给孩子建行）。
2. ✅ 加载器：`agents/<name>/`、`shared/` / `local/` 两棵树、`prompt_file`、`agents [...]`；Knowledge 的
   主题规则和折叠索引；`.gitignore`（`Longx.Agent.Layout`）。
3. ✅ 出厂 `Plugs.Agents`（spawn_agent / send_message / close_agent + 上限）、`Plugs.Goal`；起步包做过又删了——
   角色不进内核。
4. ✅ 设置页"Agent 内核"（`Longx.Agent.Settings`：全局一条 `system_settings`，项目 `agent_settings` 覆盖，
   加载器当最上层描述）、全局 agent 文件编辑、项目设置里的角色列表和「提升到 shared」。

落地时的取舍：角色声明按层**替换**（local 的顶掉 shared 的），不叠加；信任开关同时管 shared 和
local（都是仓库目录里要执行的代码）；goal 存在线程视图（ThreadState meta）里，进程退出不丢、BEAM 重启丢；
一个 agent 同角色派第二个叫 `researcher-2`。
