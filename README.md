# Longx

Ash + Phoenix 上的 agent 应用：内置 OpenAI 的 `codex-app-server` 作为 agent 引擎，
模型请求全部经过 Longx 自己的 AI 网关（`/ai/v1/*`）转发到你配置的上游（DeepSeek、GLM、阿里云百炼 Token Plan、OpenAI……），
codex 的工具能力可以用 Elixir 直接扩展。

## 启动

```sh
mix setup            # deps、数据库、npm install + 前端构建、下载内置的 codex-app-server、git 和 obscura（无头浏览器）
mix phx.server       # 0.0.0.0:7788；开发时前端资源由 Vite dev server（7789）热更新
```

手机连 LAN 调试时页面从 `http://<lan-ip>:7788` 打开，脚本要能到达 Vite：
`LONGX_DEV_HOST=<lan-ip> mix phx.server`。

模型 provider 和密钥在启动后的「设置 → 模型与 Provider」里配置（seeds 只建 DeepSeek / OpenAI 的空 provider 和 Tavily 一行，不读环境变量）；
`:live` 测试自己读 `DEEPSEEK_API_KEY` / `TAVILY_API_KEY`。

## 在 Linux 上安装（x86_64 / arm64）

[Releases](https://github.com/mjason/longx/releases) 里的 `longx-<版本>-linux-<架构>.tar.gz` 是完整包：
Erlang 运行时、Go 中间件、codex-app-server、git、obscura（无头浏览器）和构建好的前端都在里面，
**不需要**装 Erlang / Elixir / Node / Go / git / codex。

**要求**：Linux x86_64 或 arm64，glibc ≥ 2.39（Ubuntu 24.04、Debian 13 及更新的发行版；包在
`ubuntu-24.04` runner 上构建）；codex 的沙箱需要内核允许非特权用户命名空间（大多数发行版默认允许，
Docker 容器和一些加固过的系统不允许——不允许时 codex 会拒绝所有沙箱内的命令，只能用「完全访问」模式；
「设置 → 沙箱与权限」能看到检测结果和对策；沙箱能做什么、怎么放行，见下面的「沙箱」一节）。

全部装在用户自己的目录里（`~/.longx`），不需要 root。

### 安装

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

脚本做的事：识别架构 → 从 Releases 下载最新版并校验 sha256 → 解到 `~/.longx/app` → 建 `~/.longx/data` →
写一个 `systemd --user` 服务（`~/.config/systemd/user/longx.service`）并启动 → 等到端口响应后打印地址。
然后打开 `http://<这台机器>:7788`，到「设置 → 模型与 Provider」接入一个模型（DeepSeek / GLM / OpenAI 有预设，
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
（服务端每 6 小时也自己查一次，有新版本时状态栏会提示）。点「升级到 x.y.z 并重启」：服务端下载对应架构的包并校验
sha256 → 把数据库快照存到 `~/.longx/backups/longx-<旧版本>-<时间>.db`（`VACUUM INTO`，运行中也一致）→
解到 `app.new`、旧程序改名 `app.old`、新程序就位 → `systemctl --user restart longx`。页面会等新版本起来后自动刷新。
正在跑的一轮会被打断。没有 systemd 的环境会停在「已安装，等待手动重启」——自己重启进程就行。
匿名调用 GitHub API 每小时限 60 次，同一页面可以填一个 GitHub token（只需读公开仓库的权限，加密存在数据目录里）来避开。
镜像或 fork 用 `LONGX_UPDATE_REPO=<owner>/<repo>`、`LONGX_UPDATE_API=<host>` 换来源；服务名不是 `longx` 时设 `LONGX_SERVICE`。

**用脚本升级**：再跑一遍安装命令：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

它会：看当前版本 → 停服务（各项目的 codex 一并停掉，正在跑的一轮会被打断）→ 把 `data` 备份到
`~/.longx/backups/data-<时间>.tar.gz` → 下载校验新版本 → 旧程序改名 `app.old`、新程序就位 → 重启服务 → 等端口响应。
数据库迁移在启动时自动跑，`data` 目录原样保留：项目、会话、每个项目的 codex 状态和记忆、全局记忆、密钥都在。
`journalctl --user -u longx -f` 看日志。

**回退**：

```sh
sh install.sh --rollback        # 或 curl -fsSL …/install.sh | sh -s -- --rollback
```

把 `app.old` 换回来并重启。两种情况要多做一步——新版本跑过**数据库迁移**（旧版本可能认不得新表结构），
或升级了**内置的 codex**（它会迁移每个项目 CODEX_HOME 里自己的状态库）：用 `backups` 里的备份恢复 `data`
（脚本升级留的是整个 `data` 的 tar：`rm -rf ~/.longx/data && tar -C ~/.longx -xzf ~/.longx/backups/data-<时间>.tar.gz`；
网页升级留的是数据库快照：`cp ~/.longx/backups/longx-<旧版本>-<时间>.db ~/.longx/data/longx.db`，先停服务），
或者只对出问题的项目在「项目设置 → 危险操作」里重置 codex 目录。发布说明会标出带迁移或换了 codex 的版本。

升级后顺手：状态栏提示「codex 需要重启」时在进程工具里重启项目的 codex；「模型与 Provider」里预设可能给已有模型
补了新的思考档位；确认没问题后 `app.old` 可以删。

### 自己构建

`MIX_ENV=prod mix assets.build && MIX_ENV=prod mix release`（需要 Elixir 1.19 / OTP 28、Node 22、Go 1.24，
`mix setup` 会下载内置的 codex / git / obscura）得到 `_build/prod/rel/longx`，和 Release 里的一样。
发布由 `.github/workflows/release.yml` 完成：打 `v*` 标签就在 x86_64 和 arm64 的 runner 上各自原生构建并挂到
GitHub Release。

**任何兼容接口的模型列表**：Provider 菜单里「从接口获取模型」按 OpenAI 的 `GET /models` 标准向接口要列表（OpenRouter、
listenai 这类网关都是这个形状），勾选要添加的。列表带了上下文窗口、思考档位、图片支持的（OpenRouter）会一并填好，只给
id 的（listenai）用默认值，之后可以编辑。

## 沙箱

agent 的命令由 **Longx 自己**放进沙箱里跑：codex 0.154 把命令执行和文件读写抽象成了 exec-server 协议，Longx 在每个项目的
`environments.toml` 里把自己登记为唯一的执行环境（`LongxWeb.ExecSocket`），codex 发来的是"意图"——哪些目录可写、要不要网络——
落地由 Longx 的 Elixir 代码完成（Linux bubblewrap，macOS seatbelt；Windows 没有这两样，那里仍由 codex 自己沙箱）。审批、
权限申请、execpolicy 都还在 codex 里，一点没变。三种模式：

| 模式 | 能做什么 |
|---|---|
| 只读 | 读整个文件系统，什么都不能写 |
| 可写工作区（默认） | 写项目目录、/tmp 和用户的工具缓存（Linux `~/.cache`、macOS `~/Library/Caches`、Windows `%LOCALAPPDATA%`——uv/pip/npm 都放那儿）；其余只读；看不到设备；联网由开关决定 |
| 完全访问 | 不进沙箱，和你自己在终端里一样 |

**权限按需申请，不预先放开。** 这是 codex 自己的机制（Longx 打开了它的 `exec_permission_approvals` /
`request_permissions_tool`）：命令需要写沙箱外的目录或联网时，agent 在那条命令上申请（`with_additional_permissions`），
或者为整轮申请（`request_permissions`）；聊天里出现一张卡：申请了什么（写 ~/.cache/uv、联网…）和理由，按钮是
**本轮允许 / 本会话允许 / 拒绝**。批准后命令仍在沙箱里跑，只多了那一项权限；授权只活在这个会话里，不会写进项目设置。
agent 要彻底出沙箱跑一条命令（`require_escalated`）时也是一张卡：允许一次 / 以后这条命令都允许（写进该项目 codex 的
execpolicy 规则）/ 拒绝。被沙箱拒绝的命令，codex 会把结果交给 agent，由它决定申请什么——这和 codex 官方 TUI/桌面端一致。

**自动审核（默认开）。** 每次都点「允许」很烦，所以默认由 codex 自带的审核员（Guardian，`approvals_reviewer = "auto_review"`）
替你判：每个权限申请先交给一个只读的子会话——用的就是这个会话的模型（能用 low 思考档就用 low），走 Longx 的网关，按 codex
内置的风险策略（数据外泄、探测凭据、削弱安全、破坏性操作）给出 allow / deny、风险等级和理由；命令行上方一行小字
「自动审核通过 · 风险低：…」，没有卡片。审核员**拒绝**时命令不跑，agent 被告知不许绕过、要么换更安全的做法、要么停下来问你；
聊天里是一张「自动审核拒绝」卡（风险、理由、那条命令），按 **仍然允许** 就把这个动作以「用户已批准」写回 codex 的上下文
并自动发一句「请继续」，agent 下一轮重试时审核员看得到这条授权。一轮里连续拒绝 3 次 codex 会中断这一轮。真机上用 DeepSeek
Flash 验证过：申请整个 home 的写权限被拒（「比需要的宽，home 里有凭据和 SSH 材料」），只申请一个文件则通过。代价是每次申请多
一次模型调用——「设置 → 模型 → 自动审核」可以把审核换到另一个模型上（比如主会话用 qwen3.8-max、审核用 deepseek-flash，
跨 Provider 也行）并固定它的思考档位；不固定时按 codex 的规则：有 low 就用 low，否则用模型默认。改了要重启 codex。关掉（项目设置或新会话的访问模式里「自动审核」）就回到卡片；完全访问模式本来就不问，也不审。审核员和会话
本身一样是 `thread/start` 的配置，所以只能在新会话时选，不用重启 codex。

**全部放行（申请一律通过）。** 有时就是不想被拦：审批策略选「全部放行」（项目设置里设默认，或在输入框旁按会话切，下一轮
生效），codex 发来的每个申请——命令要的目录、整轮的权限、出沙箱跑——由 Longx 当场答「允许」（权限申请按 session 授予，
不会再问），没有卡片也不经过审核员，模型只看到申请通过。沙箱本身还在：这只是把「问你」换成了「替你点允许」，要连沙箱也
不要就选「完全访问」。注意「从不询问」是 codex 自己的 `never`：不问，但申请**一律拒绝**——想要不被拦的是「全部放行」，
不是它。

## 目标模式和技能

**目标**：输入框里 `/goal` 设一个目标（要达成的最终状态，可选 token 预算）。目标激活后 codex 会在每轮结束后**自己开下一轮**
继续干，直到模型把目标标记为完成、连续三轮没有进展卡住、或预算用完；会话上方一条目标栏显示状态、用掉的 token / 预算和
耗时，可以暂停、继续、编辑、清除。codex 自己开的轮次和你发的一样进历史、做 git 书签、在主页「正在进行」里能看到。这是
codex 自带的 goal 机制；模型也有 `create_goal` 工具，但只在你明确要求时才会用。

**技能**：项目里的 `.agents/skills/<名字>/SKILL.md`（以及 codex home 里的全局技能、codex 自带的样例）会被 codex 列进提示词，
模型按需读取；输入框里打 `$` 可以从列表里选一个，发送时它的 SKILL.md 整个带进这一轮。项目设置页列出找到的技能和路径。

**停止**：只要这一轮还没执行任何东西（没跑命令、没改文件、没调工具、没在等你审批），点停止就把这条消息整个收回——
思考和说了一半的话一起丢掉，历史里不留，文字回到输入框里让你改了再发（和 Claude Code 一样）。已经跑过命令的，
停止只是中断，消息和它做过的事留在历史里。

**「以后都允许」存在哪？** codex 只在 `untrusted`（每条命令都问）审批策略下才提供「以后这条命令都允许」，写进
`<数据目录>/codex_home/<项目 id>/rules/default.rules`；Longx 用的是按需申请（on-request），卡片上只有本轮 / 本会话，
「本会话允许」只活在这个 codex 进程里（进程回收后没了），所以那个 rules 目录一直是空的——长期放行请用「沙箱额外可写目录」，
或者交给自动审核。

可写工作区下的开关（项目设置里，也可以在输入框旁按会话临时改）：

- **联网**：关着时命令连不上任何网络地址（127.0.0.1 也不行）——这就是一个独立的网络命名空间。**本机的 socket 文件**
  （Docker、本地数据库、NVIDIA 驱动初始化用的 socket）在 Linux 沙箱里照常可用：Longx 不再套 codex 那层把所有 `connect`
  一起禁掉的 seccomp。macOS 的 seatbelt 会把 unix socket 一并拦住。agent 也可以按轮申请联网。
- **长期放开的目录和设备（高级）**：平时不用碰。「沙箱额外可写目录」是对这个项目长期有效的例外（比如数据集目录）；
  「放进沙箱的宿主路径」（仅 Linux）是 USB/串口、宿主 socket 这类沙箱看不到、agent 也申请不了的东西，每条命令启动时
  以 `--dev-bind` / `--bind` 绑进沙箱，其余限制不动；保存后下一条命令就生效，不用重启。

**GPU 不用设置**：有 GPU 的 Linux 机器上，每条命令的沙箱都带着**这台机器**的 GPU 设备节点（`/dev/nvidia*`，WSL2 是 `/dev/dxg`，
加 `/dev/dri`），项目换机器不用改。设备节点不是文件也不是网络——agent 读不到你的数据、连不出去，暴露面只是驱动本身，和你在终端里
跑一样（codex 的权限模型表达不了设备，官方到 0.154 也没有解决：openai/codex#3141、#19676，PR #8002 因安全顾虑关闭）。
在 WSL2 上验证过：断网的沙箱里 `--backend cuda` 直接在 GPU 上跑（DGX Spark 上 CUDA 也不再需要打开联网：驱动的本机 socket 在沙箱里直接可用）。

### 沙箱起不来时

- **Ubuntu 24.04 及更新**默认 `kernel.apparmor_restrict_unprivileged_userns=1`，没有 AppArmor 配置的程序拿不到带权限的
  用户命名空间（`bwrap: setting up uid map: Permission denied`）。**install.sh 装完会自己检测**：遇到这种情况就用 sudo 给 codex
  会用的 bwrap 加一条 AppArmor 配置（和 Ubuntu 给 Chrome、bazel 的做法一样，一次性，升级后仍有效；`LONGX_NO_SUDO=1` 则只打印不执行），
  之后也可以单独跑 `sh install.sh --fix-sandbox`。注意 **codex 优先用系统里的 `bwrap`**（PATH 上有、支持 `--perms` 就用它，
  比如 Ubuntu 的 bubblewrap 包），没有才用内置的——所以系统装了 bubblewrap 时配置里还要有 `/usr/bin/bwrap` 那一段。手动做就是：

  ```sh
  sudo tee /etc/apparmor.d/longx-bwrap <<'EOF'
  abi <abi/4.0>,
  include <tunables/global>

  profile longx-bwrap /home/*/.longx/app*/lib/longx-*/priv/codex/*/codex-resources/bwrap flags=(unconfined) {
    userns,
  }

  profile longx-system-bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,
  }
  EOF
  sudo apparmor_parser -r /etc/apparmor.d/longx-bwrap
  ```

  然后在「设置 → 沙箱与权限」点「重新检测」。`LONGX_HOME` 不是 `~/.longx` 的话改路径。整体关掉限制
  （`sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`）也行，但放开的是所有程序。
- **容器和部分虚拟机**允许用户命名空间但建不了网络命名空间（`bwrap: loopback: Failed RTM_NEWADDR`）：codex 只在命令不能联网时
  才隔离网络，所以「联网与本机服务」打开时沙箱正常，关着时每条命令都会被拒绝。设置页会标成「可用，但断网隔离不可用」。

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
  `{"kind":"approval"|"turn_completed"|"turn_failed"|"codex_down","title":…,"body":…,"url":"/p/<slug>/t/<id>","project_id":…,"thread_id":…,"at":…}`，
  `url` 前面拼上自己的服务器地址就是要打开的页面。

## 结构一览

```
lib/longx/shim*            Go 中间件：带背压、可干净终止的外部进程（codex 通过它启动）
lib/longx/codex/runtime.ex 内置 codex-app-server 的下载/校验/定位（mix codex.fetch）
lib/longx/codex/home.ex    我们自己的 CODEX_HOME 和 config.toml（codex 只认识 Longx 网关）
lib/longx/browser*         内置 obscura 无头浏览器（mix obscura.fetch）：一次一进程、许可池限并发；web.run 的 open 和 builtin.browser_fetch 用它
lib/longx/ai/              模型 provider / 搜索 provider（密钥加密存库）、网关、Tavily 搜索
lib/longx/codex/           app-server 客户端：Connection、ThreadState（ETS 视图）、Thread API、Tool 体系
lib/longx/tools/           给 codex 的 Elixir 工具 —— 见下文
lib/longx_web/             SPA 壳（所有路径）、/rpc（ash_typescript）、/socket（thread / project channel）、/ai/v1 网关、/attachments 附件上传（zip/PDF/数据集存到数据目录，消息里给 agent 一个路径）
assets/js/core/            不碰 DOM 的前端核心（RPC 客户端、socket、channel、reducer）——以后 React Native 复用
assets/js/ui/              React DOM：路由、页面、shadcn 组件；移动端优先
```

## 模型 provider：一个 provider 用一把 key，不要用号池

模型在数据库里配置（`Longx.AI.Provider` + `Longx.AI.Model`），每个 provider 一条记录，
一个 `base_url` 和一把 `api_key`。设置里的「从模版添加」备好了 DeepSeek、GLM、阿里云百炼
Token Plan（个人版 / 团队版，key 各一把、互不通用；Coding Plan 只有 Chat Completions，codex 0.154
不支持；按量计费的地址带 WorkspaceId，用「自定义」填）和 OpenAI。**联网搜索按模型决定**：
模型自带搜索的（OpenAI；百炼上的 Qwen 3.5+、DeepSeek-v4、glm-5.2）由 provider 在服务端跑 codex 的
`web_search` 工具，搜索的问题和来源会显示在聊天里；不支持的（百炼上的 kimi、MiniMax、glm-5）自动改走
Longx 的 Tavily 搜索——模板已经标好，模型编辑框里也能改。同一个 thread 可以按轮次换模型（`turn/start.model`、fork），
网关（`Longx.AI.Gateway`）负责让不同上游能接着同一段历史继续跑，其中最麻烦的是推理块：

* OpenAI 返回的 `reasoning.encrypted_content` 是**真正的密文**，只有 OpenAI 自己解得开；
  DeepSeek 一类的只是一个引用 token。不管哪家，别家的东西一律不出网关：
  目标是 OpenAI（`Provider.kind = :openai`）时只保留它自己产生的 `rs_` 推理项，
  其余目标（`:openai_compatible`，默认）收到的历史里没有任何 `encrypted_content`。
  可读的 `summary` / `reasoning_text` 保留，清空后什么都不剩的推理项直接丢掉。
* **降级路径**：OpenAI 目标如果对我们回放的推理块答 4xx（正文里提到 `encrypted` /
  `reasoning`），网关会把历史里**所有** `encrypted_content` 去掉再重试**一次**，
  并打一条 warning。对话不受影响，只是这一轮少了推理的连续性。逻辑在
  `lib/longx/ai/gateway.ex`：

  ```elixir
  defp retry_without_reasoning?(%Upstream{kind: :openai, degraded?: false}, status, body)
       when status in 400..422 do
    body =~ ~r/encrypted|reasoning/i
  end
  ```

  `degraded?` 保证只退一步：重试后仍失败就原样透传给 codex 显示。

这条降级路径是**兜底**，不是常态。OpenAI 的密文和产生它的账号/订阅绑定，换一把 key
回放上一轮的推理就解不开——如果 provider 背后是一个号池（多把 key 轮换、多个账号混用），
几乎每一轮都会先吃一个 4xx、再降级重试：延迟翻倍、推理连续性全丢、日志里全是 warning，
而且不同 key 的额度/模型可用性还不一致，表现会很不稳定。所以：

* **一个 provider 对应一把固定的 key**：官方统一 API，或者一份独立的订阅。
* 想用多个账号，就建多个 provider / model 记录，让用户在线程级别明确选择，
  而不是在同一个 provider 里悄悄轮换。
* 号池类的中转服务请标成 `:openai_compatible`：网关不会给它回放任何 `encrypted_content`，
  也不会触发上面的重试，行为反而更可预期（代价是没有推理连续性）。
  `kind` 不填时按 `base_url` 推断：只有 `api.openai.com` 是 `:openai`。

### provider 上还能配什么

| 字段 | 作用 |
| --- | --- |
| `request_timeout_ms`（默认 10 分钟） | 上游多久不吭声算超时，网关回 504；模型思考很久是正常的，别设太短 |
| `max_concurrent_requests`（默认不限） | 同时在途的请求数上限，超出网关回 429 + `retry-after`，codex 会退避重试 |
| `last_error` / `last_error_at` | 网关在线上遇到 401/403 时记下来，UI 据此提示「key 不对」 |
| `last_checked_at` | `Longx.AI.check_model/1` 的健康检查：发一个 16 token 的小请求，成功清掉 `last_error` |

### model 上的设置

| 字段 | 去向 |
| --- | --- |
| `context_window` | codex 的 `model_context_window`（压缩时机） |
| `reasoning_effort`（自由字符串，模型自己认什么就填什么） | codex 的 `model_reasoning_effort`，随请求的 `reasoning.effort` 发给上游 |
| `reasoning_summary`（`auto` / `concise` / `detailed` / `none`） | codex 的 `model_reasoning_summary` |
| `max_output_tokens` | 网关加到请求上的 `max_output_tokens`（codex 自己不设） |

这些都是**按线程**生效的：开线程时按所选模型（没选就是全局默认）算好，作为 `thread/start.config`
覆盖传给 codex，所以不同线程可以同时跑不同模型、不同搜索模式；`web_search` 的 hosted / standalone /
disabled 也按模型的 provider 决定，而不是全局一个。换模型重做某一轮时只换得了 effort / summary，
上下文窗口和搜索模式还是线程开始时那个模型的。

## 每个 project 一个 codex

Longx 不是一个 codex 服务所有会话：**每个 project 有自己的 codex-app-server 进程和自己的
`CODEX_HOME`**（`data/codex_home/<project id>/`，codex 的 sqlite、会话都在里面）。第一次用到时
才启动，坏一个只坏一个：某个 project 的 codex 崩溃/挂起，其他 project 完全无感。

崩溃时的收尾是自动的：正在跑的那一轮标成 `failed`（"codex restarted…"），线程标 `disconnected`，
codex 重启后自动 `thread/resume` 接回来；接不回来的标 `unrecoverable`。一轮超过 10 分钟没有任何
事件会被打断（`config :longx, Longx.Projects.Tracker, stall_after:`）。

codex 是 project 的资源，`Longx.Projects` 上可以管：

| 函数 | 作用 |
| --- | --- |
| `codex_info/1` | home 路径和大小、sqlite 文件、worker 状态（pid / 启动时间） |
| `stop_codex/2` / `restart_codex/1` | 停/重启；有 turn 在跑时要 `force: true` |
| `clear_codex_history/1` | 清掉 codex 的状态（对话历史没了，线程标 `unrecoverable`），保留我们的配置 |
| `reset_codex_home/1` | 整个目录删掉重建 |
| 归档 project | 停 worker，目录留着；`delete_project/2` 要 `confirm: true`，删目录，**永远不碰工作目录** |

## 原生内核（实验）

除了 codex，project 可以选 **Longx 自己的 agent 内核**（新建项目的「高级」或项目设置里的
「内核」，`Longx.Agent`）。内核只有四样东西：一个线程一个 OTP 进程、append-only 的对话日志
（`agent_items` 表，重启后照常续聊）、模型调用和工具调用（都是 task、结果都是消息）、
按阶段跑管道并执行 effects 的解释器。其余全是 **plug**——一个概念。**没有沙箱、没有审批**：
命令以你的身份直接在这台机器上跑，需要隔离时把整个 Longx 放进容器。

工具面是 codex 的，为 codex 调过的模型直接能用：`exec_command`（参数同 codex，命令跑到结束）、
`apply_patch`（codex 的 patch 语法，Elixir 实现；对 OpenAI 发 grammar 约束的 custom tool）、
`view_image`。基础 prompt 是 codex 自己的 prompt 精简版。

**一步 = 一个 `%Longx.Agent.Step{}` 流过一串 plug**，同一条管道在三个阶段跑：`:request`（拼 prompt、挂工具）、
`:response`（模型回来了、工具还没跑）、`:turn_end`（没事可做了）。plug 往 step 上放的都是数据，
包括让内核做什么的 **effect**：`Step.enqueue_call/3`（追加一条自己的工具调用，比如改了文件就跑
`mix test`）、`Step.continue/2`（不结束这一轮，再来一步）、`Step.compact/2`（先压缩上下文）、`Step.halt/2`。

**项目可以完全定制自己的 agent**——`.longx/agent.exs` 是描述，plug 是行为。`.longx/` 分两棵树：
`shared/`（agents、plugs、knowledge，进 git，审过的）和 `local/`（同样三样加一份可选的 `agent.exs`，
`.gitignore` 掉——这台机器、你自己、agent 的草稿；agent 默认写这里，你在项目设置里把审过的「提升到 shared」）：

```elixir
# .longx/agent.exs
import Longx.Agent.Config

agent do
  version 1
  extends :default                       # 出厂管道是底
  model "deepseek-flash", effort: "low"
  prompt "改完 lib/ 必须跑 mix test。"
  plug Deploy, after: Shell              # 来自 .longx/plugs/deploy.exs
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

描述记录的是**相对出厂的差异**（`extends :default` + `plug` / `options` / `drop`），所以发新版本时
出厂管道的变化会自动到达每个项目；写整张 `pipeline do … end` 才会把管道冻结住。三层同一格式：
priv 里的出厂描述、`<data>/agent/` 你自己的、项目的 `.longx/`（shared 再 local），后一层覆盖前一层。每层的 `.exs`
编译前会被改名到自己的命名空间，两个项目都叫 `Deploy` 也不冲突；每轮开始按 mtime 重载；
加载失败退回下一层，错误以提示进 prompt——agent 改坏了自己下一轮能自己修。

仓库里的 `.exs` 会以你的身份在 Longx 里执行，所以每个项目有一个开关（项目设置 →「信任并加载
.longx/ 里的定义」，默认关）。开了之后 agent 也被告知自己的定义在哪、怎么写（`priv/agent/reference.md`），
重复出现的流程它会写成 plug，和代码一起进 git。

**知识代替记忆**：`.longx/shared/knowledge/`（项目的，进 git）、`.longx/local/knowledge/`（本机的，agent
默认写这里）、`<data>/agent/knowledge/`（你自己的，自己是个 git 仓库）、`priv/agent/knowledge/`（Longx 出厂的，
只读：怎么写 plug、描述格式的版本变化）。**每篇必须属于一个主题**（`<根>/<主题>/<名字>.md`），索引按主题折成
一行（主题里的 `README.md` 代表它），`knowledge_read("local/deploy")` 列出主题下的文档——AI 写得太快，
一级目录会把 git 变成灾难。front matter 里 `always: true` 的每轮都进 prompt，`knowledge_read` /
`knowledge_search` / `knowledge_write` 三个工具读写。skill 就是一篇"怎么做 X"的知识，AGENTS.md
不在出厂管道里（要兼容的项目自己 `plug AgentsMd`）。

**子 agent = 同一套循环的另一个进程，交流 = mailbox。** 没有 wait：`spawn_agent(agent, task)` 按声明起一个
`Longx.Agent`（`Agent.spawn/4`，或 plug 里的 `Step.spawn/4` effect）立刻返回；孩子的最终回答是父 mailbox 里的
一条消息（`[agent researcher] …`）——父在跑就下一步折进上下文，父空闲就被叫醒开新的一轮（Turn 行照记）。
父 monitor 子（崩了是一条消息进上下文），子 monitor 父（父没了自己退出）。进程很轻，闲 30 分钟自退，
下一条消息从对话日志毫秒级拉起来。能派谁是**声明**：`.longx/shared/agents/<名字>/agent.exs`（同一格式：
`summary`、`prompt_file "prompt.md"`、模型、`drop Patch`、`agents [...]` 它自己能派谁）。**Longx 不带任何角色**：
没有声明时 `spawn_agent` 不出现，prompt 告诉模型怎么在 `local/agents/<名字>/` 里声明一个（下一步就能派）；
用顺了人在项目设置里提升进 `shared/`——角色是项目里长出来的，不是内核发的。模型选角色，不再临时拼模型和参数。
上限（深度、同时几个、闲置多久、孩子默认模型、reviewer 模型）在设置 → Agent 内核里配，项目设置可覆盖——
这些是每个 agent 描述最上面的一层。递归的结束由主模型判断：`Goal` plug 的 `create_goal` 让一轮在
`:turn_end` 继续下去，直到模型 `update_goal(status: complete)`（或 blocked、预算用完、单轮 8 次续跑）。

**联网**是两个 plug：`WebSearch` 看模型——provider 自己会搜的（OpenAI、百炼上的 Qwen 3.5+ 等）就发
codex 那个 `web_search` 工具、由 provider 侧搜和读，回来的 `web_search_call` 和引用在聊天里显示成搜索行；
其他模型给一个 `web_search` 函数走 Tavily。`Browser` 给所有模型一个 `web_fetch`，用内置的 obscura 渲染网页
转 markdown——provider 自己会搜也读不了你指定的 URL。会话的联网开关只管搜索。

**上下文压缩照 codex 的做法**：`Compaction` plug 决定什么时候压（超过窗口 90%、provider 报上下文
超长、模型调 `new_context_window`、你敲 `/compact`），内核在 task 里让模型写一份交接摘要，
新的上下文 = 你说过的话原文 + 摘要，UI 上一个压缩标记。

一轮正在跑的时候再输入，消息像 Codex app 那样先排在输入框上方：这一轮结束后自动作为新的一轮发出，也可以「插入」到正在跑的这一轮里，或者「取消」。你的全局知识在设置 → 知识里管理（编辑、新建、删除，每次保存一个 git 提交）。

还没做的：`write_stdin` 会话、`/review`。

### 内存：不设上限，但排好死的顺序

大任务就是要吃内存，所以默认**没有硬上限**。Longx 做的是让系统缺内存时先死该死的：

* Linux：每个 codex 进程树的 `oom_score_adj` 是 +500（BEAM 保持原值）。OOM killer 按
  「RSS + 分数」挑，先杀那个吃了 20 GB 的命令，其次 codex（那一轮标 failed，其他 project 无感），
  BEAM 永远排最后。生产用 systemd 跑时再加 `OOMScoreAdjust=-900` 更稳。
* Windows：没有 OOM killer，内存耗尽时谁分配谁崩——所以 codex 树放进一个 Job 对象，
  想限制时用 Job 的内存上限让**任务自己**分配失败，而不是拖垮 BEAM。Job 也让树杀变可靠。
* 真想限制某个 project 就设 `memory_limit_mb`（Linux 是地址空间上限 RLIMIT_AS，JVM/Go/BEAM
  这类预留地址空间的运行时要给得宽）。
* 每 5 分钟 `Longx.Codex.Recycler` 看一遍所有 codex 进程：**30 分钟没跑过轮次的停掉**（`idle_after_ms`，
  放一天的项目不占内存，下一条消息再拉起来、会话不丢），空闲且跑了 12 小时 / 树的 RSS 超 2 GB /
  跑过 200 轮的也停掉（codex 长时间运行会持续涨内存）。有 turn 在跑的绝不碰。
  设置 → codex 进程 能看到每个在跑的 codex（内存、PID、轮次、上次活动）并提前停掉。
  每次采样也发 telemetry `[:longx, :codex, :worker, :sample]`，UI 可以画资源曲线。

沙箱由 codex 自己做（Linux 用包里的 bubblewrap，需要非特权 user namespace；WSL1、多数容器不行）。
启动时 `Longx.Codex.Sandbox` 会探测一次，不可用的话 UI 会常驻提示。`workspace_write` 沙箱默认断网，
要装依赖的项目把 `network_access` 打开。

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

### 安全边界：工具跑在沙箱外

codex 自己的命令在它的沙箱里跑；**Elixir 工具没有任何沙箱**，模型给的参数直接进你的代码，
用的是 Longx 进程的全部权限。所以：

* 不要把模型给的参数拼进 shell（`System.cmd`/`Longx.Shim` 用 argv 列表，不要拼字符串）；
* 文件路径先 `Path.expand` 再确认在 `ctx.cwd`（project 根目录）之内，越界直接返回错误；
* 会产生副作用的操作（删除、推送、花钱）用 `{:defer, …}` 走审批，别默认放行；
* 输出给模型之前截断，别把整个文件/整个响应塞回去。

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

**注册 ≠ 注入。** 注册表只是目录；一个工具要真的出现在 agent 面前，必须被选中：

- **全局开关**：`Longx.AI.list_tools/0` 把注册表同步进数据库（`ai_tools` 表，新工具一律 `enabled: false`），
  `Longx.AI.enable_tool("acme.weather")` / `disable_tool/1` 打开关闭——这就是设置页面要用的接口。
- **按 thread 选择**：`Longx.Codex.Thread.start(cwd: …, tools: ["acme.weather", "builtin.thread_status"])`
  精确指定这个 thread 能用的工具（页面上勾选后传进来）；`tools: []` 一个都不给；
  **不传 `tools:` 时取全局打开的那些**——默认什么都没打开，所以默认什么都不注入。
- `available?/1` 是最后一道过滤：即使被选中，上下文不满足也不会声明。

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
