# 监控与定时（Watches）设计 v2

目标：让 agent「盯着」某些东西——定时检查、被外部事件叫醒、异常时诊断并通知人——
**不烧 token**、不引入第二套循环、会话没了自动清干净。
原则沿用内核的：**定义是文件，状态是数据库行，调度是 Oban，被叫醒的是 agent 进程（OTP 邮箱）**，
agent 侧的能力是一个 plug。

## 1. 一句话模型

> 一个 **watch** = `.longx/local/watches/<name>.exs`（或 `shared/watches/`）里的一个模块：
> **什么时候**（cron / 一次 / webhook）、**先跑什么代码验证**（`probe/1`，可选）、
> **满足什么条件才叫醒**（每次 / 变化时 / 失败时）、**叫醒哪个会话**（本会话 / 自己的会话）、**说什么**（`message/2`）。

叫醒 = 往那个会话 agent 的邮箱发一条消息（`Longx.Agent.send/3`），和子 agent 汇报叫醒父 agent 同一条路。
**没有新的循环、没有常驻 GenServer**：定义在文件，运行态在行上，调度在 Oban。

## 2. 为什么是文件而不是表单（你提的）

- **写下来才可靠**：探针是代码，跑什么、判什么、输出什么一目了然；不是 agent 往一个 JSON 里猜字段。
- **和 plug / agent 同一个模型**：同一个 Loader、同一个改名编译、同一个 `trust_local_agent` 开关
  （`local/` 总是加载——这台机器上 agent 自己写的；`shared/` 进 git，受信任才跑）、同一个 Lint、同一个 notice 通道。
- **人能干预**：在 IDE 里打开、改 cron、删文件就是删 watch；`promote` 提升到 shared 给团队。
- **自由度**：探针可以 curl、可以跑脚本、可以查凭证 API、可以读知识里的「正常态」比对——都是普通 Elixir。

代价：探针是**不经模型就跑的代码**，写错了每分钟跑一次。兜底：30 秒超时、`budget`、
`watch_run` 干跑工具（写完先跑一遍看结果）、加载失败成 notice 而不是静默。

## 3. 文件格式：`use Longx.Agent.Watch`

```elixir
# .longx/local/watches/deploy_health.exs
defmodule DeployHealth do
  use Longx.Agent.Watch

  every "*/5 * * * *"                       # 或 once "2026-09-19T08:00:00+08:00"，或 webhook true
  session :here, thread: "01a0b3ed-…"       # 工具替 agent 填的；`session :own` 则 watch 有自己的会话
  fire :on_change                           # :always | :on_change | :on_fail（有 probe 时默认 :on_change）
  busy :skip                                # :skip | :wait
  expires "2026-09-20T00:00:00+08:00"       # 可选；或 max_fires 24
  budget 6                                  # 每小时最多叫醒次数，默认 6

  @impl true
  def probe(ctx) do
    case shell(ctx, "curl -fsS -m 5 http://localhost:8080/health") do
      {:ok, 0, out} -> if out =~ ~s("status":"ok"), do: {:ok, out}, else: {:fail, out}
      {:ok, _code, out} -> {:fail, out}
    end
  end

  @impl true
  def message(_ctx, %{state: state, output: out, previous: prev}) do
    "健康检查从 #{prev} 变成 #{state}，请查日志判断是否需要重启：\n#{out}"
  end
end
```

- **头部是 DSL**（`every` / `once` / `webhook` / `session` / `fire` / `busy` / `expires` / `max_fires` / `budget`），
  和 `agent.exs` 一样是数据，`Longx.Agent.Watch.definition/1` 读出来；错的 cron、缺的 session 在加载时就报。
- **`probe/1` 可选**：没有就 `fire :always`（纯定时）。返回 `{:ok, output} | {:fail, output} | {:skip, why}`。
  `ctx`：`project_root`、`cwd`、`name`、`previous`（上次 `probe_state`）、`payload`（webhook）。
- **`message/2` 可选**：默认模板 `[watch <name>] <state> — <output 头部>`。
- `use Longx.Agent.Watch` 带来的助手：`shell/3`（`Longx.Shim.run`，cwd 项目根，超时 30 s，
  和 exec_command 同一条路，以 Longx 用户身份——**允许任何命令**，隔离是部署的事，不是内核的），
  `http/3`（Req），`credential_request/4`（`Longx.Credentials.request/4`，凭证不经模型、响应抹值），
  `knowledge_read/2`（读「正常态」）。
- **两种会话**：
  - `session :here, thread: id` —— 叫醒创建它的那个会话；会话没了 → 关掉，notice「watch X 的会话已不存在」。
  - `session :own, report_to: "main"` —— watch 有**自己的一个会话**（首次触发时建，句柄 `watch-<name>`，标题
    `⏰ <name>`，一直用同一个：历史和上下文留在那里，人可以打开看）；那个会话被人删了 → 下次触发再建一个，不报错。
    `report_to`（可选，一个句柄）：watch 会话每轮的回答送回那个会话——创建者不用醒着等；
    两边随时能 `send_message` 互相找（见 `docs/agent-directory-design.md`）。
- 层与信任：`local/watches/` 总是加载；`shared/watches/` 只在 `trust_local_agent` 打开时加载
  （它是不经模型就跑的代码——正是这个开关存在的原因）。`Layout` 多一个 kind `:watches`，`promote` 通用。
- 编译走 `Definition.Loader` 同一条路（`Longx.Agent.Local.<tag>` 改名、mtime 缓存、失败成 notice）；
  `Definition.Lint` 同样扫它。

## 4. 运行态：`Longx.Watches.Watch`（AshSqlite + AshOban）

文件是定义的真相，行是**状态**的真相，键是 `(project_id, name)`：

| 字段 | 说明 |
|---|---|
| `project_id` / `name` / `path` / `layer` | 文件在哪 |
| `kind` / `cron` / `at` / `session` | 从文件同步 |
| `thread_id` | `:here` 时来自文件；`:own` 时首次触发建的会话 |
| `next_due_at` | 调度器只看这一列 |
| `fire_policy` / `busy_policy` / `expires_at` / `max_fires` / `budget_per_hour` | 从文件同步 |
| `probe_state` | `:ok` \| `:fail` \| nil，`checked_at`，`output` 头部（≤ 2 KB），`error` |
| `enabled` / `disabled_reason` | `:by_person` \| `:thread_gone` \| `:budget` \| `:load_error` \| `:expired` \| `:done` |
| `load_error` | 文件编译/校验失败的原因（同时是 agent 提示词里的 notice） |
| `webhook_token` | `webhook true` 时生成，`POST /hooks/:token` |
| `last_fired_at` / `fired_count` / `skipped_count` | 统计 |

**同步（reconcile）**：扫每个未归档项目的 `watches/` 目录（Loader 的 mtime 缓存，没变就不动）→
新文件 upsert 行、改了的更新定义列并重算 `next_due_at`、文件没了删行。触发时机：
每分钟的 Oban Cron `Longx.Watches.Reconcile`（先于 fire 调度）、`watch_list` / `watch_run` 工具调用时、
项目设置页打开时。最坏一分钟延迟。

关系：`Thread has_many :watches`（`thread_id`）；`Project has_many :watches`。
**删会话**：`:here` 的行 → `:fire` 第一步关掉；`:own` 的行 → `thread_id` 置空，下次再建。
**删项目**：`DeleteThreads` 之后 `cascade_destroy :watches`。文件跟着工作目录，项目删除不动工作目录，行删掉即可。

## 5. 调度：ash_oban 的 trigger，一分钟一扫

```elixir
oban do
  triggers do
    trigger :fire do
      scheduler_cron "* * * * *"
      where expr(enabled and kind in [:cron, :once] and next_due_at <= now())
      action :fire
      queue :watches
      max_attempts 1
      trigger_once? true
    end
  end
end
```

现有 Oban 配置（Lite、Cron、凭证刷新）不动；`crontab` 里加 `Reconcile`，并入 `AshOban.config/1`。
`max_attempts 1`：一次没成等下一分钟，不要重试风暴。webhook 不走调度：`POST /hooks/:token` 直接调同一个 `:fire`
（带 `payload`），10 秒内多次合并成一次。

## 6. `:fire` 做什么（顺序）

1. **定义还在吗**：文件没了 / 加载失败 → 关掉（`load_error` / 删行），结束。
2. **会话还在吗**：`:here` 且 thread 不存在 / `:archived` / `:unrecoverable` → `disabled_reason: :thread_gone`，通知一次；
   `:own` 且没有会话 → `Projects.start_thread`（标题 `⏰ <name>`），记 `thread_id`。
3. **探针**：`probe/1` 在 `Longx.Watches.TaskSupervisor` 下的 Task 跑，30 秒超时；异常/超时 → `probe_state.error`，
   按 `:fail` 处理。`{:skip, why}` → 只记录，不叫。
4. **要不要叫醒**：`always` → 叫；`on_change` → 和 `previous` 不同才叫（首次也叫）；`on_fail` → 失败才叫。
   不叫就只更新 `probe_state`、`next_due_at`，**零模型调用**。
5. **配额**：这一小时已叫 ≥ `budget` → 不叫，`disabled_reason: :budget`，通知一次。
6. **会话正忙**（`Agent.status` running）：`skip` → `skipped_count`；`wait` → `deliver: :idle` 投递（内核 inbox，
   这一轮结束后作为新一轮）。**永远不插话**。
7. **叫醒**：`Projects.wake_thread(thread, text, from: "watch-<name>", deliver: :idle)`（`ensure_agent` + `seed_turns` + `Tracker.track` + `Agent.send/3`）。
   文本 = `message/2` 的结果（≤ 8 KB），前缀 `[watch <name>] `。Tracker 给这一轮一行（`user_text` `（定时触发）<name>`），推通知（kind `watch`）。
   会话有**活动的目标**（`:here`）→ 文本作为目标的续跑（goal continuation）进去，轮数与预算照旧。
8. 写回：`last_fired_at`、`fired_count`、`next_due_at`；`once` 触发后 → `:done`，**文件删掉**（一次性的消耗掉，触发消息里说明）；
   过了 `expires` / `max_fires` → `:expired`，文件保留，`watch_list` 说「已结束，可删」。

失败都落在行上，不抛、不重试；`Longx.System.Faults` 记一条。

## 7. Agent 这一侧：`Plugs.Watches`（进默认流水线）

agent **写文件**（apply_patch，它本来就会），工具只做文件做不了的事：

| 工具 | 作用 |
|---|---|
| `watch_list()` | 立刻 reconcile，列出本项目的 watch：定义、状态、上次探针结果、下次时间、加载错误 |
| `watch_run(name)` | **干跑**：现在跑一次 `probe/1` 和 `message/2`，把结果原样返回，**不叫醒、不改状态**——写完先验证 |
| `watch_bind(name)` | 把 `session :here` 的 `thread:` 填成当前会话（改文件里那一行）；`watch_create` 的替代，agent 写文件时可以直接写 |
| `watch_enable(name, bool)` | 开关（`disabled_reason: :by_person`） |
| `wait_until(at \| cron, message)` | 糖：写一个 `once`/`every` + `session :here` 的文件并结束本轮（回答里说「我 X 点再看」） |
| `notify(title, body, level)` | 主动给人推通知 |

提示词 / `priv/agent/reference.md` / `longx/knowledge/writing-watches.md`：格式、助手、返回约定、
「能用探针的就用探针」、「先 `watch_run` 再放着」、「轮次里不许 sleep 等待，要等就 `wait_until`」、
「把正常态写进知识 `local/monitor/<name>.md`」、「配额用完不要再建」。

## 8. 界面

- **项目设置 → 监控与定时**：列表（名字、层、cron/URL、会话、下次、上次探针、叫醒/跳过、开关）；
  行操作：**打开文件**（编辑器 tab）、**立即运行**（干跑，结果在对话框）、**删除**（删文件，确认）。
- **会话页**：会话挂着 watch（`:here`）或本身是 watch 的会话（`:own`）→ 标题旁 ⏰ 徽标，点开列表。
- **通知**：叫醒、暂停、会话没了都进 `Longx.Notify`（kind `watch`）。
- **Settings → 请求记录**：`request_kind: watch`。

## 9. 清理与一致性

| 情形 | 处理 |
|---|---|
| 删文件 | 下一分钟 reconcile 删行；排队的 Oban 任务读不到行 → 结束 |
| 删会话（`:here`） | `:fire` 第一步关掉，notice + 通知一次；文件留着，人/agent 改 `thread:` 或删 |
| 删会话（`:own`） | `thread_id` 置空，下次再建 |
| 删项目 | 行级联删掉；文件在工作目录里，不动 |
| 文件编译失败 | `load_error` + 关掉 + agent 提示词 notice（和 plug 一样） |
| agent 进程闲退 | `wake_thread` 从 Specs / 行拉起，和打开页面一样 |
| BEAM 重启 | Oban 从库恢复；reconcile 幂等；没有内存态 |
| 探针一直失败 | `on_fail` 每次都叫 → `budget` 兜住 |
| 同一 watch 并发 | `trigger_once?` + Oban 唯一性 |

## 10. loop 和 schedule 的关系

「再来一次」有三种，只有需要**等**的那种是 watch：

| 形态 | 谁负责 |
|---|---|
| 一轮之内反复调工具直到答完 | 内核的 step 递归（已有） |
| 跨轮次续跑直到目标完成，不用等 | `Plugs.Goal`（已有） |
| 要等时间、等事件、等探针变化再继续 | **watch** |

**schedule = watch；loop = goal + watch**。watch 只管「什么时候叫醒」，「醒来干什么、干到什么算完」是 goal 的事：
`:here` 叫醒时会话有活动目标 → 作为续跑进去；目标 `complete` → 它建的 watch（`wait_until` 写的）一并删掉。
配额各管各的：goal 的 8 轮 + watch 的每小时 `budget`。

## 11. 不做的

- 秒级调度（最小 1 分钟）。
- 常驻 watcher 进程；探针是 30 秒内的短任务，长任务是被叫醒的 agent 去做。
- 通用工作流引擎；一个 watch 叫醒一个会话，复杂逻辑交给会话（和它的团队）。
- 全局 watch（没有全局代码层，和 plug 一致）。

## 12. 工作量与拆分

| 块 | 内容 | 估计 |
|---|---|---|
| A 定义 | `Longx.Agent.Watch`（DSL + 助手 + 校验）、Layout `:watches`、Loader 加载 + notice、Lint | 0.5 天 |
| B 服务端 | 资源 + 迁移、Reconcile、ash_oban trigger、`:fire`、`wake_thread`、`:own` 会话、webhook 控制器、清理 | 1 天 |
| C agent 侧 | `Plugs.Watches` 六个工具 + 提示词 + reference + knowledge doc | 0.5 天 |
| D 界面 | 项目设置页、⏰ 徽标、通知种类 | 0.5 天 |

A → B → C；D 与 C 并行。全部 TDD（Oban.Testing 驱动 `:fire`，Bypass 扮演探针目标和模型，
临时目录里的 `.longx/local/watches/` 文件）。
