# Longx

[English](README.md) · **简体中文** · [日本語](README.ja.md)

让 agent 成为项目的一部分。

Longx 是一个本地优先的 agent 工作台：会话、文件、命令和 Git 在同一个界面里，
直连你选择的模型服务。更重要的是，它把 agent 研发当作项目的一部分：
可以查看、修改、版本管理，并和项目一起沉淀、共享。

![Longx 会话工作区](docs/media/session.png)

## 安装

macOS 14+ Apple Silicon：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install-macos.sh | sh
```

安装时需要 Python 3.9+，无需 sudo。用户级 LaunchAgent，
首次安装默认仅监听 `http://localhost:7788`。如需可信局域网访问：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install-macos.sh | sh -s -- --bind 0.0.0.0
# 也可同时指定应用版本：
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install-macos.sh | sh -s -- 0.2.115 --bind 0.0.0.0
```

其他设备访问 `http://Mac的局域网IP:7788`。升级不传 `--bind` 时保留已有监听地址；
使用 `--bind 127.0.0.1` 可恢复仅本机访问。`sh` 入口会原样传递参数，
但安装时仍需 Python。Longx 目前没有登录访问控制，请勿直接暴露公网。
签名状态和升级说明见[安装文档](docs/installation.md)。
从 v0.2.106 起，Mac 原生包使用 Developer ID 正式签名并通过 Apple 公证。
详见 [Mac 安装、升级与排障指南](docs/installation-macos.zh-CN.md)。

Linux x86_64 / arm64：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

打开 `http://<主机>:7788`，在「设置 → Provider」配置模型，然后添加项目的工作目录。
发行包自带 Erlang 运行时和前端，不需要安装开发工具链；要求 glibc ≥ 2.39
（Ubuntu 24.04、Debian 13 或更新版本）。Git 工作区功能需要机器上有 `git`。

[安装、Docker、HTTPS 与升级](docs/installation.md) ·
[完整中文参考](docs/reference.zh-CN.md) · [Releases](https://github.com/mjason/longx/releases)

> Longx 没有命令沙箱。agent 以运行 Longx 的系统用户身份执行命令；
> 需要隔离时，把整个 Longx 部署在容器或独立环境里。

## Agent 研发应该项目化

一个有用的 agent 不只是一个好 prompt，还需要项目的工具、工作规范、检查策略、
角色分工，以及解决问题后积累的知识。

Longx 最核心的区别，是这些东西的归属：**它们属于项目**。
今天调出来的有效流程，不应该只留在聊天记录里，或只存在于某位开发者的机器设置中。
把它写成文件，审查改动，提交到仓库；下一位开发者、下一台机器，就能从这里接着做。

```text
your-project/
├── AGENTS.md                  # 项目指引
├── .agents/skills/            # SKILL.md 技能文档与参考资料
└── .longx/
    ├── agent.exs              # 共享的 agent 定义
    ├── shared/                # 进入版本管理的行为、角色、知识与定时任务
    │   ├── plugs/
    │   ├── agents/
    │   ├── knowledge/
    │   └── watches/
    └── local/                 # 本机实验与覆盖配置
```

先在 `.longx/local/` 里试验，并把它加入 `.gitignore`。行为用顺了，再审查、提升到 `shared/`。
共享定义随仓库迁移；凭证、provider 配置和私人的机器状态不进仓库。
换机器时配置同名的模型别名，就可以继续使用同一份定义。

## 记忆是你能掌握的知识

值得留下的东西，要写下来，而不只是“记住”。

Longx 的长期记忆是一组 Markdown 知识文档。agent 在工作中记录有用的决策、
操作方法和经验；人可以阅读、纠正过时结论、查看差异，再把它共享给项目。
新会话可以使用这些知识，不需要重放当初学到它们的那段对话。

| 范围 | 属于谁 |
| --- | --- |
| `local` | 当前项目在本机的笔记，agent 默认写在这里 |
| `project` | `.longx/shared/knowledge/` 中审过的团队知识，和项目一起版本管理 |
| `global` | 你的偏好与机器知识，跨项目使用 |
| `longx` | Longx 自带的只读指引 |

记忆不仅要能积累，还要有结构。文档按主题组织，带标题和摘要。
agent 先看到精简的主题索引，再用 `knowledge_read` / `knowledge_search` 读取相关内容，
用 `knowledge_write` 持续维护。只有标记为 `always: true` 的短小必要文档会直接进入上下文，
而且有大小预算。

例如，审过的项目知识 `.longx/shared/knowledge/testing/checks.md`：

```markdown
---
title: Verification workflow
summary: Checks to run before accepting a change
tags: [testing]
always: false
---

Run the relevant tests, then the full project checks before reporting completion.
```

先在 `local` 中积累，审查后把有用的笔记提升到 `project`。
知识是指引，不是当前事实的证明：会变化的内容要对照代码核验，过时了就修正文档。
会话历史记录发生过什么，上下文压缩帮助当前对话继续；它们都不能替代这份可维护、
可跨会话复用的知识。

[记忆的使用与维护（English）](docs/memory.md)

## Agent 应该透明，能用代码定义和修改

Longx 的定义是普通 Elixir 文件。指令、工具、角色，甚至 loop 策略，都可以看清楚、
直接修改。agent 也可以提出这些修改；由你决定哪些成为团队共享的项目代码。

例如，给项目挂载一个行为：

```elixir
# .longx/agent.exs
import Longx.Agent.Config

agent do
  version 1
  extends :default
  model "pro"                    # 在设置里配置的别名
  prompt "Verify changes with the project's tests."
  plug ReviewOnce
end
```

`extends :default` 保留出厂行为，只叠加项目自己的差异。
用 `plug` 增加行为，`options` 调整配置，`drop` 移除不需要的 plug。
塑造自己的 agent 不需要 fork Longx。

审查代码后，在项目设置打开「信任并加载 .longx 里的定义」。
这个开关管的是随 clone 来的共享代码；`local/` 不受它限制。
修改在下一个 agent step 加载，无需重启应用；加载错误会回到 agent 面前。

### 一个看得见、改得动的 loop

这个 plug 会在 agent 准备结束时，要求再做一次自审：

```elixir
# .longx/shared/plugs/review_once.exs
defmodule ReviewOnce do
  use Longx.Agent.Plug

  def call(%Step{phase: :turn_end} = step, _opts) do
    if Map.get(step.state, :review_once_requested, false) do
      step
    else
      step
      |> Step.put_state(:review_once_requested, true)
      |> Step.continue("""
      Review your changes against the original request.
      Run any missing checks, fix issues you find, then report the result.
      """)
    end
  end

  def call(step, _opts), do: step
end
```

状态在同一轮的后续步骤中保留，下一轮重新开始，所以这个 plug 最多追加一次自审。
它是一种检查策略，不代表结果一定正确；正确性仍需要测试等确定性的检查。

同一个 plug 接口有三个阶段：`:request` 组织指令与工具，`:response` 在执行前看到工具调用，
`:turn_end` 决定是否续跑。loop 策略是项目中的代码；执行、消息和中断仍交给现有 runtime。

## 尽可能复用 OTP

我们相信 OTP 是长生命周期、并发 agent 最好的基础体系。
Longx 尽可能复用它的进程、状态机、监督树、任务和 mailbox。

每个会话是一个运行 `:gen_statem` 的 `Longx.Agent` 进程。
模型请求和工具调用在受监督的 task 中执行，结果通过消息回来。
子 agent 也是同一套 runtime 的另一个进程。

| 想做什么 | 复用什么 |
| --- | --- |
| 自定义 loop 或检查策略 | Plug 阶段函数、`Step.put_state/3` 和 `Step.continue/2` |
| 项目工具 | Plug 的 `tool` 声明和普通 Elixir 函数，由内核作为 task 执行 |
| 多 agent 协作 | 项目角色定义与 `Step.spawn/4`，报告通过 mailbox 返回 |
| 超出一轮的后台工作 | Jobs 或 watches，完成时唤醒会话 |

阶段函数保持短小、不阻塞，用 effects 和工具表达工作，让内核继续接收插入消息和停止请求。
复用现有监督与崩溃报告机制：agent 崩溃后会重启，但中断的那轮会标记失败，不会偷偷重放。

加能力时，先问：**能不能用现有 runtime 写成项目 plug？**
只有缺少通用原语时，才扩展内核。

## 定期任务也是看得见的代码

定期任务应该和它唤醒的 agent 一样透明。Longx 中的 **watch** 是普通的项目脚本：
什么时候执行、检查什么、保存哪些状态、何时通知，全都写在代码里。
你能阅读、修改、查看差异，并把它共享给团队。

调度器提供时钟，脚本决定什么值得处理。检查本身不调用模型；
只有脚本发出消息时，才唤醒 agent。

例如，每小时检查项目的依赖锁文件，建立初始基线后，只在内容变化时请求审查：

```elixir
# .longx/local/watches/lockfile_watch.exs
defmodule LockfileWatch do
  use Longx.Agent.Watch

  every "0 * * * *"
  max_runs 24

  def run(ctx) do
    content = File.read!(Path.join(ctx.project_root, "mix.lock"))
    revision = :crypto.hash(:sha256, content) |> Base.encode16()
    previous = ctx.state[:revision]

    if previous && previous != revision do
      send(ctx, :self, "The dependency lock changed. Review the update and run the relevant checks.")
    end

    log(ctx, "Dependency lock: #{String.slice(revision, 0, 12)}")
    {:ok, %{revision: revision}}
  end
end
```

返回的状态保留到下一次执行。这个 watch 最多检查 24 次，内容不变就不会唤醒模型。
`:self` 把消息送到 watch 自己的会话，后续处理有一个你能打开、查看的地方。

可以按 cron 周期运行、在指定时间运行一次，或由 webhook 触发。
用 `watch_list` 查看时间表、下一次执行、最近输出、状态与错误；
用 `watch_run` 查看日志和准备发送的消息，不实际投递。
试运行仍会执行脚本中的检查，不是沙箱，也不会回滚任意副作用。

先在 `local/watches/` 里试验，审查后把团队自动化提升到 `.longx/shared/watches/`。
共享 watch 在信任项目后加载，不需要另外声明 `plug`。
定期检查需要 Longx 服务运行，但不需要浏览器页面开着，也不需要 agent 一直占着一轮。

[Watch、定时与监控的写法（English）](priv/agent/knowledge/writing-watches.md)

## 支撑这种工作方式的工作台

接入自己的 DeepSeek、GLM、阿里云百炼、OpenAI，或兼容 OpenAI Responses API 的服务。
定义中使用模型别名，换 provider 不需要重写项目代码。

会话、agent 团队、实际文件、命令输出和 Git 变更放在一起。
响应式界面可用于桌面和手机，也有 [Android 壳](https://github.com/mjason/longx-android)。
应用界面支持简体中文与英文。

<details>
<summary>截图与视频导览</summary>

![项目主页](docs/media/welcome.png)

![文件浏览与 Markdown 预览](docs/media/file-preview.png)

[桌面视频](docs/media/tour.webm) · [手机视频](docs/media/tour-mobile.webm) ·
[手机工作区](docs/media/session-mobile.png)

</details>

## 继续阅读

- [完整中文安装、运维与扩展参考](docs/reference.zh-CN.md)
- [Plug 与项目角色](priv/agent/knowledge/writing-plugs.md)
- [Watches](priv/agent/knowledge/writing-watches.md)
- [开发与贡献](docs/development.md)

基于 Elixir/OTP、Ash、Phoenix 与 React。[MIT 许可](LICENSE)。
