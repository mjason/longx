# Longx 内核的设计模式（0.2.0）

这份文档说的是 `Longx.Agent` 现在是什么样、为什么是这样，以及往里加东西时遵守哪些形状。
来龙去脉（决策过程）在 `docs/agent-kernel-plan.md`；每个模块的实现细节在 `CLAUDE.md`。
这里只讲模式。

## 1. 内核只做四件事，其余全是 plug

内核（`lib/longx/agent.ex` + `agent/kernel/`）只有：

1. **进程**：一个会话 = 一个 `Longx.Agent` GenServer（`Longx.Agent.Registry` 登记，
   `Longx.Agent.Supervisor` 下 `restart: :temporary`）。
2. **记录**：`Longx.Agent.Transcript`，只追加的日志。每一条是 Responses API 的一个 input item
   （用户/助手消息、reasoning、function_call、function_call_output、compaction）加它在 UI 里的
   样子。模型的上下文永远是「从记录重放」，不是进程里的一块可变状态。
3. **执行**：把请求发给模型并流式读回（`Longx.Agent.Model`），把模型的工具调用作为 Task 跑起来
   （`Longx.Agent.TaskSupervisor`），把结果写回记录。
4. **解释**：按三个阶段跑 plug 管道，然后解释 plug 留在 step 上的「效果」。

其他所有东西——shell、补丁、知识、搜索、浏览器、卡片、凭证、团队、目标、压缩、对人的提问——
都是 **plug**。plug 是唯一的扩展概念：没有「技能」「工具注册表」「策略引擎」「审批器」这些第二种
东西。一个 plug 是一个 `use Longx.Agent.Plug` 的模块，实现 `init/1` 和 `call/2`，用 `tool` 宏声明
工具；工具函数就是同一个模块里的普通函数。

判断一个新能力该放哪的规则：**内核不长新分支；能写成 plug 的就写成 plug。**
内核只在「plug 表达不了」时才动，最近三次动内核分别是：效果（effects）、对人的提问（asks）、
团队（mailbox）。每次都是加一种 plug 可以使用的原语，而不是加一个功能。

## 2. 循环是 OTP 递归，邮箱是唯一的入口

一轮（turn）是这样跑的：

```
handle_continue(:step)
  ├─ 阶段 :request   —— 纯函数：plug 们往 step 上放 instructions / tools / 请求参数
  ├─ 模型流式返回     —— 在 Task 里，事件 {:model, ref, event} 进邮箱
  ├─ 阶段 :response  —— 模型的调用已知、尚未执行；plug 可以改写、追加、拦截
  ├─ 工具调用         —— 每个一个 Task，结果作为消息回邮箱
  └─ 没有调用了 → 阶段 :turn_end；否则 handle_continue(:step) 递归
```

关键约束：**回调里永远没有阻塞的 receive，也没有同步的模型调用**。模型和工具都在别的进程里，
它们的结果是邮箱里的消息。这样插话（steer）、打断（interrupt）、`/compact`、子 agent 的汇报、
人对提问的回答，全都是同一种东西：邮箱里的一条消息，在下一步被折进上下文。不需要状态机去协调
「正在等模型」和「用户想插话」，因为它们本来就在同一个队列里排队。

进程很轻，闲 30 分钟自己退出（`{:stop, :normal}`）。`Longx.Agent.Kernel.Specs`（ETS）记着它是
用什么参数 `ensure` 起来的，`send/3` 发现进程不在就原样拉起来，记录从 Transcript 重放。**没有
「恢复」这个特殊路径**：冷启动和热运行走的是同一条路。

## 3. 效果：plug 对内核说「请做这件事」

plug 不直接调内核的函数，它把意图写在 step 上，内核在每个阶段之后统一解释：

| 效果 | 阶段 | 意思 |
|---|---|---|
| `Step.enqueue_call/3` | :response | 追加一个合成的工具调用（和模型的一起执行） |
| `Step.continue/2` | :turn_end | 不结束，用这段文字再开一步（目标模式靠它续跑） |
| `Step.compact/2` | :request | 先折叠上下文再发请求 |
| `Step.halt/2` | 任意 | 结束这一轮，状态 failed |
| `Step.spawn/4` | 任意 | 派一个子 agent |
| `Step.goal/2` | 任意 | 设置/更新目标 |

这个模式的好处：plug 是**纯函数**（`Step -> Step`），可以单测、可以组合、顺序明确；
副作用集中在内核一个地方解释，出问题只查一处。`step.state` 是一轮之内跨阶段、跨步的一个 map，
给需要计数或记忆的策略 plug 用；一轮结束就清空——跨轮的东西写进知识或记录，不藏在进程里。

## 4. 描述是数据，分层记录「差异」

一个项目的 agent 长什么样，是 `Longx.Agent.Config` DSL 写的数据，不是代码：

```elixir
import Longx.Agent.Config

agent do
  version 1
  extends :default
  model "pro", effort: "high"
  prompt "……"
  plug Deploy, after: Shell
  options Shell, timeout_ms: 600_000
  drop Patch
end
```

**每一层只记录和下一层的差异**（`extends` + `plug`/`options`/`drop`），而不是整条管道的副本。
所以一个新版本改了出厂管道（比如 0.2.0 把 Compaction 和 Credentials 放进默认管道），所有项目
自动跟着变，不需要迁移用户的文件。只有显式写 `pipeline do … end` 才会冻结整条管道。

层的顺序（`Longx.Agent.Definition.Loader`）：

```
出厂默认  →  项目 .longx/agent.exs + shared/   →  .longx/local/   →  设置页（settings 层）
             （在 git 里，信任开关之后加载）        （gitignored，总是加载）
```

- `shared/` 是团队审过的、随代码提交的；`local/` 是这台机器上 agent 自己写的。
  agent 写东西默认写 `local/`；人觉得好用了「提升」到 `shared/`。角色（`agents/<name>/`）、plug、
  知识都是这三层结构。**出厂不带任何角色**——角色是项目里长出来的。
- `local/` 不受信任开关管，因为它本来就是这台机器上的 agent 写的；`shared/` 和 `agent.exs` 在
  项目被信任之前不执行，因为克隆下来的仓库里可能有别人写的代码。
- 每层的 `.exs` 先当数据解析，`defmodule` 全部改名到 `Longx.Agent.Local.<项目 tag>` 命名空间下再
  编译，所以两个项目都定义 `Deploy` 互不打架；按文件 mtime 缓存，改了下一步就生效。
- **加载失败不是错误，是通知（notice）**：坏掉的文件被跳过、下一层继续生效，一条 `⚠ …` 放在模型
  面前，agent 自己下一轮修。同样的机制用于：过时的 `version`、描述里指了不存在的 plug、指了系统
  没有的模型、以及 lint（一个 plug 自己监听端口/自己存 token/自己读环境变量里的 key——内核已经
  接管的事，提示它迁移）。这是「agent 能改自己」的安全阀：改坏了也只是收到一条提示。

## 5. 模型：按档位命名，链式回退

描述、子 agent 默认模型、作曲器、RPC 都不写具体模型名，而写档位 `ultra` / `pro` / `plus`
（旗舰/高级/普通）或团队自定义别名（青龙、朱雀…）。每个名字映射到一条**有序的模型链**
（`Longx.AI.Aliases`），`Longx.Agent.Model` 按链走：配额耗尽（429 或 quota/exhaust/balance 一类
字样）**不重试、直接换下一个**并发 `model/rerouted`；瞬时错误（5xx、传输）才退避重试。
好处是迁移提供方只改一处映射，项目里的描述一个字不用动。

请求经过 `Gateway.prepare/2` 做提供方之间的隔离：reasoning 的 `encrypted_content` 只回放给产生它的
提供方；item 的 `id` 对第三方一律不发、对 OpenAI 只发它自己形状的。这两条规则解决的是同一件事：
**一个会话的历史可以在不同提供方之间接力**，因为记录里存的是通用形状，发出去前按目标裁剪。

## 6. 记忆不存在，只有知识

没有「记忆」模块。持久的东西只有一种：**知识文档**——带 front matter 的 markdown，按
`<根>/<主题>/<名字>.md` 放，四个根：`longx/`（出厂只读）、`global/`（这个人的，跨项目）、
`project/`（`.longx/shared/knowledge`，随代码提交）、`local/`（`.longx/local/knowledge`，agent 默认写这里）。
`always: true` 的每轮进 prompt（有上限），其余只进索引一行，用 `knowledge_read` 按需读。
技能就是一份「怎么做」的文档，没有单独的加载器。

配套的优先级规则写在 prompt 里：**出厂的 `longx/` 文档和 plug 的指引高于本地/项目/全局里与之冲突的
文档**——一份在旧版本时写下的「唯一办法」不能压过新版本的能力，冲突时先改本地的。

## 7. 团队：更多的同一种进程，靠邮箱说话

没有 wait 工具，没有共享收件箱，没有编排器。`spawn_agent(role, task)` = 按角色声明
`Longx.Agent.ensure(parent: 我)` 再 `send(task)`，立刻返回。孩子在自己的进程里跑同一个循环，
它的最终回答是父邮箱里的一条消息——父在跑就下一步折入，父空闲就被叫醒开一轮。agent 之间的话
是前缀 `[agent name]` 的用户消息（Responses API 没有通用的 agent role）。

- 做完的孩子**仍是成员**（working / done / idle），`send_message` 在它保留的记录上继续追问：
  前缀稳定，提供方的 prompt 缓存能命中。只有 `close_agent` 才移除。
- 兄弟 agent 之间可以互相问，回答路由给提问者（`reply_to`），父通过 `subAgentActivity` 看到全过程。
- 父 monitor 子（异常退出变成一条消息进上下文），子 monitor 父；不 link，不 trap_exit。
- 深度和并发上限来自设置层；到了上限工具不出现、prompt 说明原因。
- 父空闲退出后从 Specs 重建团队；BEAM 重启后从 Thread 行重建。

## 8. 对人的提问是一条正式通道

工具需要人做点什么（登录、填个值、选一项）时不打印链接到终端，而是 `Context.ask/2`：线程上出现
一个 `longx/action/request`（标题、说明、链接按钮、字段或一棵 `present` 词表的表单），状态栏说
「等待你操作」，通知推到手机；工具的 Task 阻塞在那里等答案。回答可以来自三处，都是同一个入口：
人点了卡片（`Agent.respond/3`）、第三方浏览器回跳（`GET /callback/:id` 或 `/callback/credentials`）、
人把回跳地址贴回来（回环回调时）。工具拿到的是结构化答案，模型看到的是工具的一句话结果。

密钥永远不经过模型：`Longx.Credentials` 加密保存 API key 和 OAuth2 token，`http_request` 由服务层
代发（只发给白名单主机、不跟随跳转、响应里抹掉值、过期先刷新），Oban 后台续期；建凭证时密钥要么
从机器上已有的地方拷（`secret_from`），要么人在遮罩字段里输。

## 9. 卡片和界面：模型画的是数据，前端负责渲染

`present` 工具让模型用固定词表（assistant-ui 的 generative UI：Card、Fact、Table、Chart、Markdown、
Form…）描述一棵 JSON 树，前端按词表渲染；`prompt_user` 用同一棵树做表单等人选；plug 自己的
Elixir 代码可以 `Context.present/2` 不经模型直接推一张卡。词表的 schema 从前端的库生成到
`priv/agent/present.json`，precommit 校验不过期——**模型能画什么由前端决定，一处定义**。

文件相关的四个工具（`show_file` / `show_diff` / `send_file` / `show_html`）只在项目里发「打开」
的意图，工作台的标签页是纯数据（`core/workbench.ts`），只有实时到达的项才自动打开，回放不打开；
原生客户端以后按标签种类开自己的窗口。html 走沙箱 iframe（无 same-origin）。

## 10. 事件与视图：单写者，序号，快照

内核不直接推 UI，它发的是带 codex 词汇的事件（`turn/started`、`item/*`、`turn/completed`…）到
`Longx.Agent.ThreadState`——每个活跃线程一个**单写者**进程，把事件折进 ETS（增量原地追加、
`item/completed` 整体替换），分配严格递增的 `seq`，再广播。客户端协议永远是：订阅 → 拿快照
（带 seq）→ 只应用 `seq` 更大的事件。页面刷新、断线重连、子 agent 页面都是这一个协议。
读快照直接读 ETS，写者停了也能读。

## 11. 有意不做的事

- **不做沙箱、不做审批、不做策略引擎。** 命令以运行 Longx 的这个用户身份执行；隔离是部署的事
  （整个 Longx 放进容器），不是内核的事。审批式的「本轮允许/永远允许」在 0.1.x 试过，去掉了。
- **不做工具注册表。** 工具是 plug 的一部分，随 plug 加载；没有全局开关页。
- **不做全局的代码层。** 跨项目共享的只有知识；全局 agent、全局 plug 都没有——一个项目的经验
  要通过「提升到 shared/ + 提交」流动，而不是悄悄影响所有项目。
- **不做「记忆」。** 见第 6 节。
- **不做出厂角色。** 见第 4 节。
- **不打包二进制。** git 用机器上的；obscura 钉死版本并校验、按需下载，或用 `LONGX_OBSCURA` 指向
  镜像自带的；PATH 上的 obscura 不用。

## 12. 往里加东西时

1. 先问：这是 plug 能表达的吗？绝大多数是。写 plug（工具 = 同模块的函数；要影响请求就在
   `:request` 加 instructions/tools；要在模型回答后介入就在 `:response`；要改「轮次怎么结束」就在
   `:turn_end` 用效果）。
2. 如果 plug 表达不了，加的应该是一种**原语**（一个新效果、一种新消息、一个 `Context` 函数），
   而不是一个功能分支；然后原来那个功能仍然作为 plug 用这个原语实现。
3. 对人可见的行为写成 ask、卡片或 notice，不写成日志或终端输出。
4. 每个提供方相关的差异放在 `Gateway.prepare/2`（发出前裁剪），不放在记录里。
5. 测试用 Bypass 扮演模型（`Longx.Test.ResponsesFixture`），一个测试给自己的 `pipeline:`；
   开发服务器上用 playwright 看一眼真实页面再算完成。
