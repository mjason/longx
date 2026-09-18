# 会话目录与 agent 间通讯（Directory & Messaging）设计

目标：项目里的 agent **能发现彼此的存在、能互相说话、能收到回答**——不限于父子团队。
watch 的 `session :own` 会话、一个长期盯服务的「值班」会话、人自己开的几个会话，都是同一张目录里的条目。

## 1. 已经有的（不重做）

| 已有 | 在哪 |
|---|---|
| 任意会话的邮箱：`Longx.Agent.send(thread_id, text, from:, reply_to:)`——在跑 = 插话（下一步进入上下文），空闲 = 开一轮（Tracker 给它一行），进程闲退了从 `Specs` / 行拉起 | `Longx.Agent` |
| 回答自动送回去：一轮结束时最后一条 assistant 消息发给 `reply_to`（没有则父） | `Kernel.Team.report_to_parent/3` |
| agent 之间的话是 `[agent <name>] …` 的用户消息，UI 带 `from` | 内核 / `messages.ts` |
| 团队目录：children / siblings（`Specs`，进程走了也在） | `Kernel.Team`、`Plugs.Agents` |
| 通知流 `Longx.Notify`、`Projects.running_threads/0` | `Longx.Projects` |

**缺的**：根会话没有名字；agent 看不见团队之外的会话；`send_message` 只认队友；
消息只能插话，不能「等它空了再说」。

## 2. 身份：每个会话一个句柄（handle）

- `Thread` 加 `handle`：项目内唯一的短 slug（`[a-z0-9][a-z0-9-]*`，≤ 32），可空。
- 来源：**人**在会话重命名对话框里填（默认按标题生成建议）；**agent 自己**用 `claim_handle(name)` 认领
  （它想被别人找到时——值班、长期任务）；**watch 的 `:own` 会话**自动得到 `watch-<name>`；
  **子 agent** 沿用团队里的名字，全局地址是 `<根句柄>/<名字>`（`agent_path` 已经是这个形状）。
- 没句柄的会话也能被找到和称呼：目录里显示 `~<id 前 6 位>`，`send_message("~01a0b3")` 也能送到。
- `from` 的推导（`Projects.agent_name/1`）：句柄 → 团队名 → `~<id 前 6 位>`。人发的消息 `from` 仍是 nil。

## 3. 目录：`Projects.directory/2`——一个查询，不是一个进程

`directory(project_id, scope: :project | :all)` 把三处合成一张表，每行：

| 列 | 来自 |
|---|---|
| `handle` / `title` / `preview` | Thread 行 |
| `state` | `running`（进程在跑）/ `waiting`（有 ask 挂着）/ `idle`（进程在、空闲）/ `asleep`（进程闲退，行在，可拉起）/ `archived` |
| `goal` | `ThreadState.Store`（目标模式的 objective/status） |
| `team` | `Specs.children_of/1`：它的子 agent 名字与状态 |
| `watches` | `Longx.Watches`：挂在它上的 / 它本身是哪个 watch 的会话 |
| `last_activity_at` / `project` | Thread 行；`:all` 时带项目 slug，地址写成 `<project-slug>:<handle>` |

只读 ETS + 一次行查询，没有新的 GenServer；单用户系统，跨项目可见、可发（`scope: :all` 才列出来）。

## 4. 通讯：一个原语，两种投递

**原语不变**：`Agent.send/3`。扩两处：

1. **地址解析**：`Projects.resolve_address(project_id, "deploy-health" | "main/researcher" | "~01a0b3" | "other-proj:main")`
   → thread id。团队名优先（队友先于全局同名）。
2. **投递方式** `deliver: :now | :idle`：
   - `:now`（默认，今天的行为）：在跑就插话（steer 仍在 state 里排队——它要进*下一步*，不是等空闲）。
   - `:idle`：**消息留在邮箱里，等状态变成空闲时由 OTP 重投**——`:gen_statem` 的 `postpone`：
     `running` 状态收到 `{:agent_message, …, deliver: :idle}` → `{:keep_state_and_data, :postpone}`，
     切到 `idle` 的那一刻自动重新投递、作为新一轮开始。没有手工队列。
     watch 的 `busy :wait` 就用它。进程闲退（`state_timeout`）前邮箱里被 postpone 的消息已经重投过，不会丢在退出里。
   - 空闲 / 闲退：两种都是「开一轮」。

### 前提：`Longx.Agent` 从 GenServer 换成 `:gen_statem`（第 0 块）

内核本来就是状态机（`phase: :idle | :step`，`handle_continue(:step)` 递归，`:idle_check` 定时器），换成
`:gen_statem`（`handle_event_function`）后：显式状态 `:idle` / `:running` / `:waiting`（有 ask 挂着）；
`{:next_event, :internal, :step}` 代替 `handle_continue`；进入 `:idle` 自动起 `state_timeout`（30 分钟闲退）、
离开自动消；`deliver: :idle` 的消息和运行中收到的 `/compact` 用 `:postpone`。
**对外 API 不动**：`GenServer.call/cast/stop` 对 gen_statem 进程照常有效（`$gen_call` 就是它的 `{:call, from}` 事件），
`Registry` via 不变；`agent_test` 整套是安全网。~40 个回调子句改写成 `handle_event/4`，约 1 天。

回答仍靠 `reply_to`：`send_message(to, message, expect_reply: true)` 把本会话 id 放进 `reply_to`，
对方那一轮的最后一条消息就回到本会话邮箱（在跑插话、空闲开轮）——**不等待、不阻塞**，和团队汇报一模一样。
`expect_reply: false` 是纯通知（默认 true）。

### 工具（`Plugs.Agents`，现有三个工具的扩展，不加新 plug）

| 工具 | 变化 |
|---|---|
| `agents_directory(scope?)` | 新：第 3 节那张表 |
| `send_message(to, message, deliver?, expect_reply?)` | `to` 从「队友名」扩成「任意地址」 |
| `claim_handle(name)` | 新：给本会话起句柄 |
| `spawn_agent` / `close_agent` | 不变 |

提示词加一节 `# Others in this project`：目录摘要（≤ 20 行：句柄、状态、一句话、目标），
「要找人做长期的事先看目录，有值班的就发消息而不是再开一个」，「收到 `[agent x]` 的消息，
回答写在最后一条消息里就会送回去；要主动找它就 `send_message(x, …)`」。

## 5. 主题（第二步，可选）：一对多

点对点够用之后再加：`announce(topic, message)` / `subscribe(topic)` / `unsubscribe(topic)`，
主题是项目内的字符串（`deploy`, `alerts`）。订阅要跨进程存活 → 存在 Thread 行的 `subscriptions`（字符串数组）；
announce = 查订阅者 → 逐个 `Agent.send(…, deliver: :idle, from: …)`。webhook 型 watch 可以 announce 而不是只叫醒一个会话。
**不做**：消息队列、持久化投递、ack——邮箱语义够了，丢了就是丢了（会话删了消息也没意义）。

## 6. 和 watch 的接法

- `session :own` 会话句柄 `watch-<name>`；创建它的会话（写文件的那个）在文件里写 `report_to "main"`
  （或工具 `watch_bind` 填），watch 会话每轮的回答按 `reply_to` 送回创建者——**创建者不用醒着等**。
- 创建者随时 `send_message("watch-deploy-health", "昨晚看到什么了？")`；watch 会话也能反过来找它。
- watch 叫醒用 `deliver: :idle`：永远不插话（原设计的 skip/wait 变成 skip / idle 投递）。

## 7. 界面

- **Agents 工具窗**（`background-inbox`）从「本会话的子 agent」扩成「项目目录」：每行句柄 / 状态 / 一句话 / 目标 / ⏰，
  点开跳到那个会话；本会话的团队一段在上面。
- 会话重命名对话框加「句柄」；标题旁显示 `@handle`。
- agent 间的消息已有 `from` 展示；`deliver: :idle` 排队中的消息在目标会话的 TurnBar 上显示「有 N 条待处理」。

## 8. 清理与一致性

| 情形 | 处理 |
|---|---|
| 目标会话删了 / 归档 | `send` 返回 `{:error, :not_found}` → 工具结果告诉 agent，目录里也没了 |
| 目标会话 `:unrecoverable` | 同上，结果里说明 |
| 发送方在回答到达前闲退 | `report_to_parent` 已处理：Task 里 `Agent.send` 拉起它 |
| 发送方删了 | 回答 `send` 失败，记 `Faults` 一条，丢弃 |
| 句柄冲突 | 唯一索引；`claim_handle` 返回错误并列出已用的 |
| 邮箱里 postpone 的消息、BEAM 重启 | 丢（邮箱是内存态）；watch 下一分钟会再来，agent 消息由发送方自己判断重发 |
| 循环互发（A 问 B，B 问 A…） | 每条消息带 `hops`（回答 +1），> 6 不再自动回送；目标模式的 8 轮和 max_steps 仍在 |

## 9. 不做的

- 不做全局 / 跨机器目录（单节点）；不做 MQ；不做权限（单用户）。
- 不做「等待回复」的阻塞工具——回答是邮箱里的下一条消息，和团队一致。

## 10. 工作量

| 块 | 内容 | 估计 |
|---|---|---|
| A 身份与目录 | `handle` 列 + 迁移 + 校验、`Projects.agent_name/1`、`directory/2`、`resolve_address/2`、RPC | 0.5 天 |
| 0 状态机 | `Longx.Agent` → `:gen_statem`（状态显式、`state_timeout`、`postpone`），测试不变 | 1 天 |
| B 投递 | `Agent.send` `deliver: :idle`（`postpone`）、`hops` | 0.5 天 |
| C 工具与提示词 | `agents_directory`、`send_message` 扩地址、`claim_handle`、`# Others` 段、reference | 0.5 天 |
| D 界面 | Agents 工具窗目录、重命名对话框句柄、待处理计数 | 0.5 天 |
| E 主题 | 第二步 | 0.5 天 |

顺序：0 → A → B → C，D 并行；watch 的服务端（另一份设计的 B 块）依赖这里的 A、B。
