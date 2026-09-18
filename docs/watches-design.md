# 监控与定时（Watches）设计 v3

目标：让 agent「盯着」某些东西——定时检查、被外部事件叫醒、异常时诊断并通知人——
**不烧 token**、不引入第二套循环、会话没了自动清干净。

原则：**watch 是一个普通脚本，Oban 是钟，邮箱是出口。** 脚本被定时唤醒，自己判断，
想跟哪个会话说话就 `send` 过去；运行时不替它决定策略。定义是文件，运行态是数据库行。

## 1. 一句话模型

> 一个 **watch** = `.longx/local/watches/<name>.exs`（或 `shared/watches/`）里的一个模块：
> 头部说**什么时候跑**（`every` cron / `once` 一个时间点 / `webhook`），`run/1` 是**跑什么**。
> 跑的时候能 `shell` / `http` / `credential_request` / `knowledge_read`，能 `send(ctx, 会话, 话)`，
> 返回的 map 是下次的 `ctx.state`。

三种用法，同一个形状：

| 用法 | 脚本里怎么写 |
|---|---|
| **loop**（像 claude 的 /loop：过一会儿再叫我） | `send(ctx, "main", "继续：…")`——发起会话的句柄 |
| **监控** | 定期跑探测；`if 变了, do: send(ctx, "main", …)`；`{:ok, %{status: s}}` 记住这次 |
| **own**（有自己会话的值班） | `send(ctx, :self, …)`——句柄和 watch 同名的会话，没有就建 |

`send` 默认 `deliver: :idle`：**永远不插话**，对方在跑就留在它邮箱里，空了作为新一轮
（内核 gen_statem 的 postpone，见 `docs/agent-directory-design.md`）。

## 2. 文件格式：`use Longx.Agent.Watch`

```elixir
# .longx/local/watches/deploy_health.exs
defmodule DeployHealth do
  use Longx.Agent.Watch

  every "*/5 * * * *"                     # 或 once "2026-09-19T08:00:00+08:00"，或 webhook true
  expires "2026-09-20T00:00:00+08:00"     # 可选；或 max_runs 24
  timeout 30_000                          # 可选，默认 30 s

  def run(ctx) do
    {code, out} = shell(ctx, "curl -fsS -m 5 http://localhost:8080/health")
    status = if code == 0, do: :ok, else: :fail

    if status != ctx.state[:status],
      do: send(ctx, "main", "健康检查从 #{ctx.state[:status] || "未知"} 变成 #{status}，请查日志：\n#{out}")

    {:ok, %{status: status}}
  end
end
```

- **头部是 DSL**（`every` / `once` / `webhook` / `expires` / `max_runs` / `timeout`），和 `agent.exs` 一样是数据，
  `Longx.Agent.Watch.definition/1` 读出来；错的 cron 在加载时就报。
- **`run/1`** 返回 `{:ok, state}`（map，≤ 8 KB，下次的 `ctx.state`）| `{:error, why}`（落行，成 notice）。
  `ctx`：`name`、`project_root`、`state`（上次的）、`payload`（webhook 的 body）、`run_at`。
- **助手**（`use Longx.Agent.Watch` 带来）：
  `shell(ctx, cmd, opts)` → `{exit_code, output}`（`Longx.Shim.run`，cwd 项目根，脚本 timeout 内，Longx 用户——**任何命令**，隔离是部署的事）；
  `http(ctx, url, opts)`（Req）；`credential_request(ctx, name, url, opts)`（`Longx.Credentials.request/4`，凭证不经模型、响应抹值）；
  `knowledge_read(ctx, path)`；
  **`send(ctx, to, text, opts)`**：`to` 是句柄 / `~id` / `"<project>:<handle>"` / `:self`；
  `deliver: :idle`（默认）| `:now`；`from` 固定 `watch-<name>`；返回 `:ok | {:error, :not_found | :budget}`。
- **`:self`**：`Projects.session_named(project, "watch-<name>")`——找句柄同名的会话，没有就 `start_thread`
  （标题 `⏰ <name>`）。人删了 → 下次再建。
- 层与信任：`local/watches/` 总是加载；`shared/watches/` 只在 `trust_local_agent` 打开时加载
  （不经模型就跑的代码——正是这个开关的用途）。`Layout` 多一个 kind `:watches`，`promote` 通用。
  编译走 `Definition.Loader` 同一条路（`Longx.Agent.Local.<tag>` 改名、mtime 缓存、失败成 notice）；`Definition.Lint` 同样扫。

## 3. 运行态：`Longx.Watches.Watch`（AshSqlite + AshOban）

文件是定义的真相，行是状态的真相，键 `(project_id, name)`：

| 字段 | 说明 |
|---|---|
| `project_id` / `name` / `path` / `layer` | 文件在哪 |
| `kind` / `cron` / `at` / `expires_at` / `max_runs` | 从文件同步 |
| `next_due_at` | 调度器只看这一列 |
| `state` | 脚本上次返回的 map |
| `running_since` | 正在跑（Oban 任务开始时写、结束清）——**管理后台看「在运行什么」靠它** |
| `last_run_at` / `last_duration_ms` / `last_error` / `last_output` | 上次跑的结果（output = 脚本 `log/2` 写的头部 ≤ 2 KB） |
| `runs` / `sends` / `sends_this_hour` / `hour_started_at` | 统计与配额（默认 6 次/小时，`budget` 头部可改） |
| `enabled` / `disabled_reason` | `:by_person` \| `:load_error` \| `:budget` \| `:expired` \| `:done` |
| `load_error` | 文件编译/校验失败（同时是 agent 提示词里的 notice） |
| `webhook_token` | `webhook true` 时生成，`POST /hooks/:token` |

**Reconcile**：扫每个未归档项目的 `watches/` 目录（Loader 的 mtime 缓存）→ 新文件 upsert、改了的更新并重算
`next_due_at`、文件没了删行。触发：每分钟 Oban Cron `Longx.Watches.Reconcile`、`watch_list` / `watch_run` 工具、
项目设置页打开时。关系：`Project has_many :watches`，删项目 → `cascade_destroy`（文件在工作目录，不动）。

## 4. 调度：ash_oban trigger，一分钟一扫

```elixir
trigger :run do
  scheduler_cron "* * * * *"
  where expr(enabled and kind in [:cron, :once] and next_due_at <= now() and is_nil(running_since))
  action :run
  queue :watches
  max_attempts 1
  trigger_once? true
end
```

现有 Oban 配置不动，`crontab` 加 `Reconcile`，并入 `AshOban.config/1`。`max_attempts 1`：没成等下一分钟。
webhook 不走调度：`POST /hooks/:token` 直接调 `:run`（带 `payload`），10 秒内多次合并。

## 5. `:run` 做什么

1. 文件没了 / 加载失败 → 关掉（`load_error`），结束。
2. `running_since = now`；在 `Longx.Watches.TaskSupervisor` 下的 Task 里跑 `run/1`，`timeout` 到 → 杀掉，`last_error: :timeout`。
3. 脚本里的 `send` 走 `Projects.deliver(project, to, text, from: "watch-<name>", deliver: :idle)`：解析地址、`:self` 找或建会话、
   `ensure_agent` + `Tracker.track` + `Agent.send/3`；配额满 → `{:error, :budget}` 给脚本，行 `disabled_reason: :budget`，通知人一次。
   Tracker 给被叫醒的那一轮一行（`user_text` `（定时触发）<name>`），推通知（kind `watch`）。
4. 写回：`state`、`last_*`、`runs`、`running_since = nil`、`next_due_at`；`once` 跑完 → `:done`，**文件删掉**（一次性的消耗掉）；
   过了 `expires` / `max_runs` → `:expired`，文件保留，`watch_list` 说「已结束，可删」。

失败都落在行上，不抛、不重试；`Longx.System.Faults` 记一条。BEAM 重启时 `running_since` 非空的行由 boot 清零（和 `settle_after_restart` 一起）。

## 6. Agent 这一侧：`Plugs.Watches`（进默认流水线）

agent **写文件**（apply_patch），工具只做文件做不了的事：

| 工具 | 作用 |
|---|---|
| `watch_list()` | 立刻 reconcile，列出本项目的 watch：定义、启用、上次结果、下次、正在跑、加载错误 |
| `watch_run(name)` | **干跑**：现在跑一次 `run/1`，`send` 只记录不投递，结果原样返回——写完先验证 |
| `watch_enable(name, bool)` | 开关 |
| `wait_until(at \| cron, message)` | 糖：写一个 `once`/`every` 文件，`run` 就是 `send(ctx, "<本会话>", message)`，然后结束本轮 |
| `notify(title, body, level)` | 主动给人推通知 |

提示词 / reference / `longx/knowledge/writing-watches.md`：格式、助手、返回约定、你的句柄（Environment 里）、
「轮次里不许 sleep 等待，要等就 `wait_until`」、「先 `watch_run` 再放着」、「正常态写进知识」、「配额用完不要再建」。

## 7. 界面（管理后台要能知道在运行什么）

- **项目设置 → 监控与定时**：列表：名字、层、cron / 一次 / webhook、启用、**状态**（`运行中 12 s` / 空闲 / 已关：原因）、
  上次（时间、耗时、错误或输出头部）、下次、跑过 / 发过、最近发给谁。行操作：打开文件（编辑器 tab）、立即运行（干跑，结果对话框）、
  开关、删除（删文件，确认）。列表订阅 `ProjectChannel` 的 `"watches"` 推送（`running_since` 变化就推），不用轮询。
- **全局 Settings → 监控与定时**：所有项目的 watch 一张表，正在跑的在最上面；和 Oban 队列状态（排队 / 执行中）一起。
- **会话页**：会话是某个 watch 的 `:self` 或最近被 watch 叫醒过 → 标题旁 ⏰ 徽标。
- **通知**：叫醒、暂停、加载失败进 `Longx.Notify`（kind `watch`）。
- **Settings → 请求记录**：`request_kind: watch`。

## 8. 清理与一致性

| 情形 | 处理 |
|---|---|
| 删文件 | 下一分钟 reconcile 删行；排队的 Oban 任务读不到行 → 结束 |
| `send` 的目标会话没了 | 脚本得到 `{:error, :not_found}`；`:self` 会重建 |
| 删项目 | 行级联删掉；文件在工作目录里，不动 |
| 文件编译失败 | `load_error` + 关掉 + 提示词 notice（和 plug 一样） |
| 目标会话进程闲退 | `Agent.send` 从 Specs / 行拉起 |
| BEAM 重启 | Oban 从库恢复；`running_since` 清零；reconcile 幂等 |
| 脚本一直发 | 每小时配额兜住 |
| 同一 watch 并发 | `trigger_once?` + `is_nil(running_since)` |

## 9. loop 和 schedule 的关系

「再来一次」有三种，只有需要**等**的那种是 watch：一轮之内的工具循环（内核）；跨轮次续跑不用等（`Plugs.Goal`）；
要等时间 / 事件 / 探测变化（watch）。**schedule = watch；loop = goal + watch**：`wait_until` 写的 watch 叫醒时会话若有活动目标，
消息作为目标续跑进去；目标 `complete` 时它写的 watch 一并删掉。

## 10. 不做的

- 秒级调度（最小 1 分钟）；常驻 watcher 进程；通用工作流引擎；全局 watch（没有全局代码层）。
- 运行时不做「策略」：变化检测、失败判定、发给谁，都是脚本的 `if`。

## 11. 工作量与拆分

| 块 | 内容 | 估计 |
|---|---|---|
| A 定义 | `Longx.Agent.Watch`（DSL + 助手 + `send` + 校验）、Layout `:watches`、Loader、Lint | 0.5 天 |
| B 服务端 | 资源 + 迁移、Reconcile、trigger、`:run`、`Projects.deliver` / `session_named`、webhook、清理、boot 清零 | 1 天 |
| C agent 侧 | `Plugs.Watches` 五个工具 + 提示词 + reference + knowledge doc + Environment 里的句柄 | 0.5 天 |
| D 界面 | 项目设置页、全局页、⏰ 徽标、`"watches"` 推送 | 0.5 天 |

依赖 `docs/agent-directory-design.md` 的 0（gen_statem）、A（句柄与目录）、B（`deliver: :idle`）。
