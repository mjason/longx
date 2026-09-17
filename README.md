# Longx

Ash + Phoenix 上的 agent 应用，跑的是 **Longx 自己的 agent 内核**（`Longx.Agent`）：一个会话一个 OTP 进程，
模型调用和工具调用都是 task，其余一切都是 **plug**。模型请求直接发到你配置的上游（DeepSeek、GLM、阿里云百炼、
OpenAI，或任何 OpenAI 兼容接口）；agent 的行为、工具、角色、知识都长在项目的 `.longx/` 目录里，用 Elixir 写、
下一步生效。前端是 React 19 + assistant-ui 的单页应用，手机优先。

包里不带任何第三方二进制：git 用机器上的，无头浏览器第一次用到时才下载。

## 启动（开发）

```sh
mix setup            # deps、数据库、npm install + 前端构建（不下载任何二进制）
mix phx.server       # 0.0.0.0:7798（开发端口，和生产的 7788 错开）；前端资源由 Vite dev server（7799）热更新
```

手机连 LAN 调试时页面从 `http://<lan-ip>:7798` 打开，脚本要能到达 Vite：`LONGX_DEV_HOST=<lan-ip> mix phx.server`。
开发数据都在仓库里：根目录的 `longx_dev.db`，`data/` 下的附件、全局知识和下载来的浏览器（都不进 git）。

模型 provider 和密钥在启动后的「设置 → 模型与 Provider」里配置（seeds 只建 DeepSeek / OpenAI 的空 provider 和
Tavily 一行，不读环境变量）；`:live` 测试自己读 `DEEPSEEK_API_KEY` / `TAVILY_API_KEY`。

## 在 Linux 上安装（x86_64 / arm64）

[Releases](https://github.com/mjason/longx/releases) 里的 `longx-<版本>-linux-<架构>.tar.gz` 是完整包：
Erlang 运行时、Go 中间件和构建好的前端都在里面，**不需要**装 Erlang / Elixir / Node / Go。
无头浏览器（obscura）不在包里：先找 PATH 上的 `obscura`（有就直接用，不下载——Docker 镜像里装一个即可），
没有才在 agent 第一次调用 `web_fetch` 时自动下载到 `$LONGX_DATA_DIR/obscura`（设置 → Agent 内核 里有进度条，
也可以先手动下载；Longx 升级后旧版本继续可用，卡片上一键升级）。容器里也可以直接挂载 `data/obscura`。

**要求**：Linux x86_64 或 arm64，glibc ≥ 2.39（Ubuntu 24.04、Debian 13 及更新的发行版；包在 `ubuntu-24.04`
runner 上构建）。机器上要有 `git`（项目的轮次书签、全局知识的版本控制都靠它；没有也能跑，只是这些功能退化）。
其余命令行工具见下面的「系统依赖」。**没有沙箱**：agent 的命令以运行 Longx 的用户身份直接在这台机器上跑，
需要隔离就把整个 Longx 放进容器。

全部装在用户自己的目录里（`~/.longx`），不需要 root。

### 安装

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

脚本做的事：识别架构 → 从 Releases 下载最新版并校验 sha256 → 解到 `~/.longx/app` → 建 `~/.longx/data` →
写一个 `systemd --user` 服务（`~/.config/systemd/user/longx.service`）并启动 → 等到端口响应后打印地址。
然后打开 `http://<这台机器>:7788`，到「设置 → 模型与 Provider」接入一个模型（DeepSeek / GLM / 百炼 / OpenAI 有预设，
填 API Key 就行；密钥加密存在数据目录里，不走环境变量）。

可以调的：

```sh
LONGX_HOME=~/apps/longx LONGX_PORT=8080 sh install.sh      # 换目录、换端口
sh install.sh 0.1.0                                          # 指定版本
LONGX_NO_SERVICE=1 sh install.sh                             # 只安装不启动（没有 systemd 的环境也会自动降级成这样，并打印手动启动的命令）
loginctl enable-linger "$USER"                               # 服务器：不登录也让用户服务常驻
```

手动启动就是 `LONGX_DATA_DIR=~/.longx/data PORT=7788 ~/.longx/app/bin/longx start`；`PHX_HOST` 是生成链接用的主机名
（默认 `localhost`）；`SECRET_KEY_BASE` / `LONGX_CLOAK_KEY` 可以代替数据目录里自动生成的密钥文件。
`data/cloak_key` 加密 provider 的 API key，**丢了就读不回来**——备份 `~/.longx/data` 时一起备份。
要 TLS 就在前面放一个反向代理（Caddy / nginx），Longx 自己只说 http。

### 升级

**在网页里升级**：「设置 → 版本与更新」显示当前版本，「检查更新」问 GitHub Releases 有没有新版本
（服务端每 6 小时也自己查一次，有新版本时状态栏会提示）。点「升级到 x.y.z 并重启」：服务端下载对应架构的包
（有进度条）并校验 sha256 → 把数据库快照存到 `~/.longx/backups/longx-<旧版本>-<时间>.db`（`VACUUM INTO`，运行中也一致）→
解到 `app.new`、旧程序改名 `app.old`、新程序就位 → `systemctl --user restart longx`。页面会等新版本起来后自动刷新。
正在跑的一轮会被打断。没有 systemd 的环境会停在「已安装，等待手动重启」——自己重启进程就行。
匿名调用 GitHub API 每小时限 60 次，同一页面可以填一个 GitHub token（只需读公开仓库的权限，加密存在数据目录里）来避开。
镜像或 fork 用 `LONGX_UPDATE_REPO=<owner>/<repo>`、`LONGX_UPDATE_API=<host>` 换来源；服务名不是 `longx` 时设 `LONGX_SERVICE`。

**用脚本升级**：再跑一遍安装命令：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

它会：看当前版本 → 停服务（正在跑的一轮会被打断）→ 把 `data` 备份到 `~/.longx/backups/data-<时间>.tar.gz` →
下载校验新版本 → 旧程序改名 `app.old`、新程序就位 → 重启服务 → 等端口响应。
数据库迁移在启动时自动跑，`data` 目录原样保留：项目、会话、对话日志、知识、密钥、浏览器都在。
`journalctl --user -u longx -f` 看日志。

**回退**：

```sh
sh install.sh --rollback        # 或 curl -fsSL …/install.sh | sh -s -- --rollback
```

把 `app.old` 换回来并重启。新版本跑过**数据库迁移**时（旧版本可能认不得新表结构）要多做一步：用 `backups` 里的备份恢复
`data`（脚本升级留的是整个 `data` 的 tar：`rm -rf ~/.longx/data && tar -C ~/.longx -xzf ~/.longx/backups/data-<时间>.tar.gz`；
网页升级留的是数据库快照：`cp ~/.longx/backups/longx-<旧版本>-<时间>.db ~/.longx/data/longx.db`，先停服务）。
发布说明会标出带迁移的版本。确认没问题后 `app.old` 可以删。

### 自己构建

`MIX_ENV=prod mix assets.build && MIX_ENV=prod mix release`（需要 Elixir 1.19 / OTP 28、Node 22、Go 1.24，
不下载任何二进制）得到 `_build/prod/rel/longx`，和 Release 里的一样。
发布由 `.github/workflows/release.yml` 完成：打 `v*` 标签就在 x86_64 和 arm64 的 runner 上各自原生构建并挂到
GitHub Release。

## 系统依赖

agent 靠一组命令行工具干活，Longx **只检测、只提醒，不代装**：`rg`（ripgrep）、`fd`（Debian 上叫 `fdfind`）、`fzf`、
`bat`（`batcat`）、`jq`、`tree`、`git`、`gh`、`delta`（git-delta）。「设置 → 系统依赖」列出每一项有没有、什么版本，
缺的给出这台机器的安装命令；状态栏会提示「缺少 N 个依赖」。

```sh
sudo apt install -y ripgrep fd-find fzf bat jq tree git gh git-delta      # Debian / Ubuntu
brew install ripgrep fd fzf bat jq tree git gh git-delta                  # macOS
```

## 模型：provider、档位与别名

模型在数据库里配置（`Longx.AI.Provider` + `Longx.AI.Model`），每个 provider 一条记录，一个 `base_url` 和一把
`api_key`（加密存库）。设置里的「添加 Provider」先给预设：DeepSeek、GLM、阿里云百炼 Token Plan（个人版 / 团队版，
key 各一把、互不通用；按量计费的地址带 WorkspaceId，用「自定义」填）和 OpenAI；任何兼容接口都能「从接口获取模型」
（OpenAI 的 `GET /models` 标准；OpenRouter 这类会带上下文窗口、思考档位、图片支持，只给 id 的用默认值）。
上游一律是 OpenAI **Responses API**。**一个 provider 一把固定的 key，不要用号池**：OpenAI 返回的推理密文和产生它的账号绑定，
换 key 回放就解不开；想用多个账号就建多个 provider，让人明确选。

**联网搜索按模型决定**：模型自带搜索的（OpenAI；百炼上的 Qwen 3.5+、DeepSeek-v4、glm-5.2）由 provider 在服务端搜，
搜索的问题和来源显示在聊天里；不支持的走 Longx 的 Tavily 搜索——预设已标好，模型编辑框里也能改。

**模型用档位和别名来指，不要写死**：「设置 → 模型 → 档位与别名」里有三档 `ultra`（旗舰）/ `pro`（高级）/ `plus`（普通），
还可以加团队自己的别名（青龙、朱雀……），每个名字映射一条链——第一个是用的，后面是它配额用完、密钥被拒、上游挂了时的备选。
描述、子 agent、对话框里都可以写这些名字（也仍可以写具体 slug）；换 provider 时只改这里的映射，`.longx` 一个字不用动。
一轮里主选不可用会自动换到备选并在界面上提示；配额用尽不再傻等重试。对话框里显示的永远是这一轮真正会用的模型：
项目描述指定了模型，就显示它，你另选一个才覆盖。agent 自己也被告知有哪些档位、别名和模型可以在描述里写。

不同上游之间的推理块由 `Longx.AI.Gateway` 处理：OpenAI 目标只保留它自己产生的 `rs_` 推理项，其他目标收到的历史里
没有任何 `encrypted_content`（可读的 `summary` / `reasoning_text` 保留），所以同一个会话可以按轮次换模型。

| provider 字段 | 作用 |
| --- | --- |
| `request_timeout_ms`（默认 10 分钟） | 上游多久不吭声算超时；模型思考很久是正常的，别设太短 |
| `max_concurrent_requests`（默认不限） | 同时在途的请求数上限；超出时内核按退避间隔重试几次，还不行这轮失败 |
| `last_error` / `last_checked_at` | 上游 401/403 时记下来；「检测」发一个 16 token 的小请求 |

| model 字段 | 去向 |
| --- | --- |
| `context_window` | 压缩上下文的依据（窗口的 90%） |
| `reasoning_levels` / `reasoning_effort` | 模型声明的思考档位和默认档；每轮可以在对话框里换 |
| `reasoning_summary` | 请求的 `reasoning.summary` |
| `max_output_tokens` | 请求的 `max_output_tokens` |

## 内核

内核只有四样东西：一个会话一个 OTP 进程（`Longx.Agent`，闲 30 分钟自退、下一条消息从对话日志毫秒级拉起来）、
append-only 的对话日志（`agent_items` 表，重启后照常续聊）、模型调用和工具调用（都是 task、结果都是消息）、
按阶段跑管道并执行 effects 的解释器。其余全是 **plug**——一个概念。**没有沙箱、没有审批**。

工具面是 codex 的，为 codex 调过的模型直接能用：`exec_command`（参数同 codex，命令跑到结束）、
`apply_patch`（codex 的 patch 语法，Elixir 实现；对 OpenAI 发 grammar 约束的 custom tool）、`view_image`。
基础 prompt 是 codex 自己的 prompt 精简版。

**一步 = 一个 `%Longx.Agent.Step{}` 流过一串 plug**，同一条管道在三个阶段跑：`:request`（拼 prompt、挂工具）、
`:response`（模型回来了、工具还没跑）、`:turn_end`（没事可做了）。plug 往 step 上放的都是数据，
包括让内核做什么的 **effect**：`Step.enqueue_call/3`（追加一条自己的工具调用，比如改了文件就跑 `mix test`）、
`Step.continue/2`（不结束这一轮，再来一步）、`Step.compact/2`（先压缩上下文）、`Step.halt/2`、`Step.spawn/4`（派一个子 agent）。

### 项目定制：`.longx/`

`.longx/agent.exs` 是描述，plug 是行为。`.longx/` 分两棵树：`shared/`（agents、plugs、knowledge，进 git，审过的）和
`local/`（同样三样加一份可选的 `agent.exs`，`.gitignore` 掉——这台机器、你自己、agent 的草稿；agent 默认写这里，
你在项目设置里把审过的「提升到 shared」）：

```elixir
# .longx/agent.exs
import Longx.Agent.Config

agent do
  version 1
  extends :default                       # 出厂管道是底
  model "pro", effort: "high"            # 档位 / 别名 / slug 都行
  prompt "改完 lib/ 必须跑 mix test。"
  plug Deploy, after: Shell              # 来自 .longx/shared/plugs/deploy.exs
  plug TestsAfterEdit
  options Shell, timeout_ms: 300_000
end
```

```elixir
# .longx/shared/plugs/tests_after_edit.exs
defmodule TestsAfterEdit do
  use Longx.Agent.Plug

  def call(%Step{phase: :response} = step, _opts) do
    if Enum.any?(step.calls, &(&1.name == "apply_patch")),
      do: Step.enqueue_call(step, "exec_command", %{"cmd" => "mix test --failed"}),
      else: step
  end

  def call(step, _opts), do: step
end
```

描述记录的是**相对出厂的差异**（`extends :default` + `plug` / `options` / `drop`），所以发新版本时出厂管道的变化会
自动到达每个项目；写整张 `pipeline do … end` 才会把管道冻结住。同一格式的层：priv 里的出厂描述、项目的 `.longx/`
（shared 再 local）、设置页，后一层覆盖前一层——**全局层面没有代码**，没有全局的 agent、plug 或技能，跨项目共享的
只有全局知识。每层的 `.exs` 编译前会被改名到自己的命名空间，两个项目都叫 `Deploy` 也不冲突；每轮开始按 mtime 重载；
加载失败退回下一层，错误以提示进 prompt——agent 改坏了自己下一轮能自己修。

仓库里的 `.exs` 会以你的身份在 Longx 里执行，所以每个项目有一个开关（项目设置 →「信任并加载 .longx/ 里的定义」，
默认关）——它管的是 `agent.exs` 和 `shared/`（clone 来的代码）；`local/` 不进 git、是这台机器上 agent 自己写的，
**不用开关，一直加载**。agent 总是被告知自己的定义在哪、怎么写（`priv/agent/reference.md`：自定义工具就是两个文件，
`local/plugs/x.exs` 加 `local/agent.exs` 里一行 `plug X`，下一步生效，写坏了以提示回到它面前）；写了不存在的模型
不会让那一轮失败，而是以提示告诉它、先用默认模型跑。重复出现的流程它会写成 plug，你审过再提升进 `shared/`。

### 子 agent 和角色

**子 agent = 同一套循环的另一个进程，交流 = mailbox。** 没有 wait：`spawn_agent(agent, task)` 按声明起一个
`Longx.Agent`（`Agent.spawn/4`，或 plug 里的 `Step.spawn/4` effect）立刻返回；孩子的最终回答是父 mailbox 里的
一条消息（`[agent researcher] …`）——父在跑就下一步折进上下文，父空闲就被叫醒开新的一轮（Turn 行照记）。
父 monitor 子（崩了是一条消息进上下文），子 monitor 父（父没了自己退出）。孩子的每次动作在父会话里显示成一行
（开始、交互、完成），点开是它自己的会话。

能派谁是**声明**：`.longx/shared/agents/<名字>/agent.exs`（同一格式：`summary`、`prompt_file "prompt.md"`、模型、
`drop Patch`、`agents [...]` 它自己能派谁）。**Longx 不带任何角色**：没有声明时 `spawn_agent` 不出现，prompt 告诉模型
怎么在 `local/agents/<名字>/` 里声明一个（下一步就能派）；用顺了人在项目设置里提升进 `shared/`——角色是项目里长出来的，
不是内核发的。上限（嵌套深度 2、同时几个、闲置多久、孩子默认模型）在设置 → Agent 内核里配，项目设置可覆盖。
递归的结束由主模型判断：`/goal` 或 `create_goal` 让一轮在 `:turn_end` 继续下去，直到模型 `update_goal(status: complete)`
（或 blocked、预算用完、单轮 8 次续跑）。

### 工具要人做事

登录、验证码、扫码这类事有正式通道：plug 里 `Context.ask(ctx, title:, text:, url:, callback: true)`，线程上出现一张卡
（标题、说明、「打开链接」、「已完成」/「取消」，或要填的字段），输入框上方显示「等待你操作」，手机也会收到通知；
`callback: true` 时 Longx 给一个自己的回调地址（`<外部访问地址>/callback/<id>`）让第三方跳回来，参数直接交到工具手里——
不要在服务器本机开端口等浏览器，人往往在另一台机器上。外部访问地址在设置 → Agent 内核里填，不填就用你浏览器连上来的地址。
终端输出里的 URL 可以点。

### 知识代替记忆

四个根：`.longx/shared/knowledge/`（项目的，进 git）、`.longx/local/knowledge/`（本机的，agent 默认写这里）、
`<data>/agent/knowledge/`（你自己的，跨项目；机器上有 git 时自己是个 git 仓库、每次保存一个提交，没有 git 就是普通文件）、
`priv/agent/knowledge/`（Longx 出厂的，只读：怎么写 plug、描述格式）。**每篇必须属于一个主题**（`<根>/<主题>/<名字>.md`），
索引按主题折成一行（主题里的 `README.md` 代表它），`knowledge_read("local/deploy")` 列出主题下的文档——AI 写得太快，
一级目录会把 git 变成灾难。front matter 里 `always: true` 的每轮都进 prompt，`knowledge_read` / `knowledge_search` /
`knowledge_write` 三个工具读写。skill 就是一篇「怎么做 X」的知识，AGENTS.md 不在出厂管道里（要兼容的项目自己
`plug AgentsMd`）。全局知识在设置 → 知识里管理（编辑、新建、删除）。

### 联网和浏览器

**联网**是两个 plug：`WebSearch` 看模型——provider 自己会搜的就由 provider 侧搜和读，回来的搜索和引用在聊天里显示成
搜索行；其他模型给一个 `web_search` 函数走 Tavily。`Browser` 给所有模型一个 `web_fetch`，用 obscura 渲染网页转
markdown——provider 自己会搜也读不了你指定的 URL。会话的联网开关只管搜索。

obscura（`h4ckf0r0day/obscura`，Rust + V8）**先找系统的，再按需下载**：`LONGX_OBSCURA` → PATH 上的 `obscura`
（容器镜像里装一个就永远不下载）→ 下载到数据目录（开发 `data/obscura`，生产 `$LONGX_DATA_DIR/obscura`，
按 `<版本>/<平台>/` 存放；Longx 升级后旧下载继续可用，设置里显示「可升级」一键换成新版并清掉旧的）。第一次
`web_fetch` 触发下载，设置 → Agent 内核 的卡片和状态栏都有进度条，下载中工具会告诉模型「正在下载 N%」。
一页一个进程，到期连进程树一起杀；许可池限并发；默认拒绝内网地址（设置里可以放开）。

### 上下文压缩

照 codex 的做法：你敲 `/compact`、或 provider 报上下文超长时内核自己压；出厂管道里的 `Compaction` plug 再加上「超过窗口
90% 自动压」和给模型的 `new_context_window` / `get_context_remaining`（项目可以 `drop` 它或改阈值）。内核在 task 里让模型写一份交接摘要，新的上下文 = 你说过的话原文 +
摘要，UI 上一个压缩标记。

一轮正在跑的时候再输入，消息先排在输入框上方：这一轮结束后自动作为新的一轮发出，也可以「插入」到正在跑的这一轮里，
或者「取消」。停止一轮时如果它还什么都没做（只在想、只在说话），输入的文字会退回输入框。

还没做的：`write_stdin` 会话、`/review`。

## 手机：Android 壳

局域网裸 HTTP 装不了 PWA，所以手机端是一个自己的 WebView 壳：[longx-android](https://github.com/mjason/longx-android)
（首次启动填服务器地址，之后可改；返回键先关抽屉和弹窗；通知不依赖 FCM）。它靠 Longx 的两样东西，写别的壳（iOS）也是这两样：

- **桥**：页面里有 `LongxAndroid.post(json)`（iOS 是 `webkit.messageHandlers.longx`）时，页面装上 `window.LongxShell`。
  页面 → 壳：`{"type":"ready","version":1,"theme":{…}}`、`{"type":"theme","theme":{"scheme":"dark","frame":"#15171c","ground":"#1c1e24"}}`
  （拿去刷状态栏/导航栏颜色）、`{"type":"openExternal","url":…}`（交给系统浏览器）、
  `{"type":"pick","id":…,"title":"模型","sections":[{"label":"DeepSeek","options":[{"id":…,"label":…,"detail":…}]}],"selected":…}`
  （请壳弹一个原生的单选列表，选完调 `LongxShell.picked(id, optionId)`，取消传 null——手机上 popover 难用，模型/思考档位就这样选）。
  壳 → 页面：`LongxShell.back()` 返回 true 表示关掉了一个抽屉/弹窗（false 就自己 `goBack()` 或退后台）、
  `LongxShell.navigate("/p/<slug>/t/<id>")` 处理通知深链接、`LongxShell.resume()` 回前台时重连。
- **通知 feed**：Phoenix channel `notify`（`ws://<host>/socket/websocket?vsn=2.0.0`，消息是 `[join_ref, ref, topic, event, payload]`：
  加入 `["1","1","notify","phx_join",{}]`，每 30 s 心跳 `[null,"2","phoenix","heartbeat",{}]`）。加入的回复带 `running`（正在跑的会话，
  `waiting` 为 true 的在等你）；之后每条 `"event"` 是
  `{"kind":"approval"|"turn_completed"|"turn_failed","title":…,"body":…,"url":"/p/<slug>/t/<id>","project_id":…,"thread_id":…,"at":…}`
  （`approval` 就是上面那种等你操作的卡），`url` 前面拼上自己的服务器地址就是要打开的页面。

## 结构一览

```
lib/longx/agent.ex          内核循环：一个会话一个 GenServer，阶段 + effects
lib/longx/agent/kernel/     循环用到的零件：State、Team（子 agent）、Goal、Asks、Calls、Compaction、Specs、Stream、UI
lib/longx/agent/definition/ 描述 DSL（Config）、分层加载（Loader）、.longx 布局（Layout）、内核设置（Settings）
lib/longx/agent/plugs/      出厂 plug：Environment、Base、Shell、Patch、ViewImage、Knowledge、WebSearch、Browser、Agents、Goal、Request、Compaction、Local、AgentsMd
lib/longx/agent/            Step、Plug、Tool、Context、Pipeline、Transcript（对话日志）、ThreadState（ETS 视图）、Knowledge、Model
lib/longx/ai/               模型 provider / 档位与别名 / 搜索 provider（密钥加密存库）、请求整形、请求记录
lib/longx/browser*          obscura 无头浏览器：按需下载（Installer，带进度）、一次一进程、许可池限并发
lib/longx/projects/         项目、会话、轮次（git 书签）、Tracker、文件与 git 工具、附件
lib/longx/system/           系统依赖检测、目录浏览、设置项；lib/longx/upgrade.ex 自升级；lib/longx/git.ex 机器上的 git
lib/longx/shim*             Go 中间件：带背压、可干净终止的外部进程（命令、git、浏览器都通过它）
lib/longx_web/              SPA 壳（所有路径）、/rpc（ash_typescript）、/socket（thread / project / notify channel）、/callback、/attachments
assets/js/core/             不碰 DOM 的前端核心（RPC 客户端、socket、channel、reducer）——以后 React Native 复用
assets/js/ui/               React DOM：路由、页面、assistant-ui 元素、shadcn 组件；移动端优先
priv/agent/                 基础 prompt、apply_patch 语法、压缩 prompt、给 agent 的 API 参考、出厂知识
```

## 扩展指南：写一个 plug

给 agent 加能力不用改 Longx：在项目里写一个 plug，放进 `.longx/local/plugs/`，在 `local/agent.exs` 里 `plug` 上，
下一步就生效（agent 自己也会这么做——它拿到的说明就是 `priv/agent/knowledge/writing-plugs.md`）。一个带工具的 plug：

```elixir
# .longx/local/plugs/deploy.exs
defmodule Deploy do
  use Longx.Agent.Plug

  instructions "Deploy with the deploy tool, never by hand."

  tool :deploy, "Ships the current branch to an environment", show: :command, timeout: 300_000 do
    param :env, {:enum, ["staging", "prod"]}, "Target environment", required: true
  end

  def deploy(%{"env" => env}, ctx) do
    Context.emit(ctx, "deploying…\n")
    {output, status} = System.cmd("./deploy.sh", [env], cd: ctx.cwd, stderr_to_stdout: true)
    if status == 0, do: {:ok, output, %{"exitCode" => 0}}, else: {:error, "deploy failed (#{status}):\n" <> output}
  end
end
```

```elixir
# .longx/local/agent.exs
import Longx.Agent.Config

agent do
  version 1
  extends :default
  plug Deploy
end
```

- **工具函数是普通 Elixir**，在 task 里跑、受 `timeout:` 约束（默认 60 s）：`System.cmd`、`File`、`Req`、`Jason` 都能用，
  只有文件的顶层要保持纯粹（它是数据，评估时不能有副作用）。
- 参数类型 `:string` / `:integer` / `:number` / `:boolean` / `{:enum, [..]}` / `{:array, type}`；不写 `required: true` 就是可选。
- 返回 `{:ok, text}`（模型读到的）、`{:ok, text, meta}` 或 `{:error, why}`（模型读到错误后重试或解释）。
  `meta` 里内核认得 `"exitCode"`（命令行显示）、`"image"`（一个 data URL，模型接着看到）、`"compact" => true`（下一步前先压缩）。
- `show:` 决定 UI 上那一行：`:command` 终端块、`:file_change` diff、`:web_search` 搜索行、`:tool` 普通调用。
- 位置：`plug Deploy` 默认放在 `Request` 前；`plug Guard, after: Shell` 指定位置；`options Shell, timeout_ms: …` 改出厂 plug 的选项；
  `drop ViewImage` 去掉一个。
- 要人参与就 `Context.ask/2`（上面「工具要人做事」），要派人就 `Step.spawn/4`，要接着干就 `Step.continue/2`。
- 完整 API 在 `priv/agent/reference.md`；出厂 plug 在 `lib/longx/agent/plugs/` 里，照着写。

## 测试

```sh
mix test                          # 单元测试；模型由 Bypass 扮演，浏览器是一个假脚本
mix test --include integration    # 真的下载 obscura 渲染一个 Bypass 页面
mix test --include live           # 真 DeepSeek / Tavily，需要对应的 API key
mix precommit                     # 提交前：编译零警告、格式、Go 检查、前端检查、全部单测
```

## 了解更多

* [Ash](https://hexdocs.pm/ash) · [Phoenix](https://hexdocs.pm/phoenix) · [assistant-ui](https://www.assistant-ui.com)
* 内核设计的来龙去脉：`docs/agent-kernel-plan.md`

MIT 许可，见 `LICENSE`。
