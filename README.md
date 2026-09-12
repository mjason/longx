# Longx

Ash + Phoenix 上的 agent 应用：内置 OpenAI 的 `codex-app-server` 作为 agent 引擎，
模型请求全部经过 Longx 自己的 AI 网关（`/ai/v1/*`）转发到你配置的上游（DeepSeek、GLM、OpenAI……），
codex 的工具能力可以用 Elixir 直接扩展。

## 启动

```sh
mix setup            # deps、数据库、前端资源、下载内置的 codex-app-server（priv/codex/）
mix phx.server       # 0.0.0.0:7788
```

环境变量：`DEEPSEEK_API_KEY`（seeds 会把它写进 DeepSeek provider）、`TAVILY_API_KEY`（联网搜索）、`OPENAI_API_KEY`（可选）。
生产环境另需 `LONGX_CLOAK_KEY`（加密 provider 密钥）和 `LONGX_DATA_DIR`（codex 的状态目录）。

## 结构一览

```
lib/longx/shim*            Go 中间件：带背压、可干净终止的外部进程（codex 通过它启动）
lib/longx/codex/runtime.ex 内置 codex-app-server 的下载/校验/定位（mix codex.fetch）
lib/longx/codex/home.ex    我们自己的 CODEX_HOME 和 config.toml（codex 只认识 Longx 网关）
lib/longx/ai/              模型 provider / 搜索 provider（密钥加密存库）、网关、Tavily 搜索
lib/longx/codex/           app-server 客户端：Connection、ThreadState（ETS 视图）、Thread API、Tool 体系
lib/longx/tools/           给 codex 的 Elixir 工具 —— 见下文
```

## 扩展指南：给 agent 添加 Elixir 工具

codex 自带 shell、文件编辑、联网搜索等工具。Longx 在此之上允许你用 Elixir 写工具，
让 agent 能调用你系统里的任何能力（查数据库、读当前 thread 的状态、调内部服务……）。
机制上这些是 codex 的 *dynamic tools*：`thread/start` 时声明给模型，模型调用时 codex 发
`item/tool/call` 给 Longx，Longx 执行后把结果送回去。

### 1. 一个工具 = 一个模块，放进目录就生效

```
lib/longx/tools/
├── builtin/                 # Longx 自带的，namespace "builtin"
│   ├── echo.ex
│   └── thread_status.ex
└── <你的命名空间>/           # fork 后加自己的，例如 acme/
    └── weather.ex
```

实现 `Longx.Codex.Tool` behaviour，`Longx.Codex.Tool.Registry` 在启动时扫描整个应用、
自动登记所有实现了这个 behaviour 的模块——**没有任何中央列表要改**，上游更新也不会和你的文件冲突。

```elixir
defmodule Longx.Tools.Acme.Weather do
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "weather"                 # 模型看到的工具名

  @impl true
  def namespace, do: "acme"               # 你的命名空间；不写默认 "builtin"

  @impl true
  def description do                      # 写给模型读：干什么、什么时候用
    "Current weather for a city. Use it whenever the user asks about weather."
  end

  @impl true
  def input_schema do                     # JSON Schema (draft 7)，string key
    %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string", "description" => "City name"}},
      "required" => ["city"],
      "additionalProperties" => false
    }
  end

  @impl true
  def call(%{"city" => city}, %Longx.Codex.Tool.Context{} = _ctx) do
    {:ok, "It is sunny in #{city}."}
  end
end
```

可选回调：

| 回调 | 默认 | 用途 |
|---|---|---|
| `namespace/0` | `"builtin"` | 分组；模型按 `namespace.name` 区分同名工具 |
| `available?/1` | `true` | 按 thread 决定是否声明这个工具（比如需要有 project 才有意义） |
| `timeout/0` | `30_000` ms | 超时会被强制终止并回报给模型 |

### 2. 参数已经校验过了

模型传来的 `arguments` 先按 `input_schema/0` 校验，不通过的调用**不会进到 `call/2`**，
模型会收到具体的 JSON pointer 错误和完整 schema，自己改正后重试：

```
invalid arguments for acme.weather:
  #/city: Type mismatch. Expected String but got Integer.
The arguments must match this JSON schema:
{"type":"object","properties":{...},"required":["city"],...}
```

所以 `call/2` 里放心用函数头模式匹配；键是字符串。

### 3. 返回值

```elixir
{:ok, "一段文本"}                                   # 最常见
{:ok, [{:text, "看这张图"}, {:image_url, "https://…/a.png"}]}   # 混合内容
{:error, "explain what went wrong and what to do instead"}   # 失败：模型会读到这句话
```

**任何失败——`{:error, _}`、抛异常、超时——都作为"工具调用失败"正常回给模型**，不会中断 turn，
也不会影响连接；模型看到的和一个失败的 shell 命令是一样的。

### 4. 上下文 `Longx.Codex.Tool.Context`

```elixir
%Longx.Codex.Tool.Context{
  thread_id: "…", turn_id: "…", call_id: "…",
  cwd: "/path/of/thread",           # thread 的工作目录
  snapshot: fn -> … end,            # 惰性读取该 thread 的物化视图（items、挂起审批、token 用量）
  project: nil,                     # 预留给 thread ↔ project 映射
  assigns: %{}                      # 你自己的扩展位
}
```

`Longx.Tools.Builtin.ThreadStatus` 就是靠 `snapshot` 让 agent 自省当前 thread 的例子。

### 5. 配置

```elixir
# config/config.exs
config :longx, Longx.Codex.Tool,
  extra: [OtherApp.SomeTool],        # 不在 :longx 应用内的模块
  disabled: ["builtin.echo"]         # 按 "namespace.name" 关掉
```

同一个 `namespace.name` 出现两次会在启动时直接报错，不会静默覆盖。
每个 thread 声明哪些工具由 `Longx.Codex.Thread.start/1` 的 `tools:` 决定：`:auto`（默认，所有 `available?/1` 的工具）、
`[]`、或模块列表。

### 6. 观测

每次调用发出 `:telemetry` 事件 `[:longx, :codex, :tool, :start | :stop | :exception]`，
metadata 含 `namespace`、`name`、`thread_id`、`call_id`、`success`。

### 7. 测试你的工具

`call/2` 是普通函数，直接单测。要走完整链路，用 `test/support/fake_app_server.exs`
（一个脚本化的假 app-server）：发送用户消息 `call acme.weather {"city":"Paris"}`，
它会向 Longx 发起 `item/tool/call` 并把回复放进 agent 消息——见 `test/longx/codex/thread_test.exs`
里 `builtin.thread_status` 的用例。真 codex 的端到端在 `test/longx/codex/gateway_e2e_test.exs`
（`mix test --include integration`）。

## 测试

```sh
mix test                          # 单元 + 假 app-server
mix test --include integration    # 内置的真 codex，上游用 Bypass 模拟
mix test --include live           # 真 DeepSeek / Tavily，需要对应的 API key
mix precommit                     # 提交前：编译零警告、格式、Go 测试、全部单测
```

## 了解更多

* [Ash](https://hexdocs.pm/ash) · [Phoenix](https://hexdocs.pm/phoenix)
* codex app-server 协议：https://learn.chatgpt.com/docs/app-server（精确 schema 用
  `priv/codex/<target>/bin/codex-app-server generate-json-schema` 生成）
