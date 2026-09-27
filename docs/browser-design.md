# 浏览器（Browser）设计 v1

目标：让 agent 能**操作人的浏览器**——打开页面、读无障碍树、点、输、截图、看 console——
用来调试自己写的页面、在已登录的站点里办事。Longx 在服务器上，Chrome 在人手边的机器上，
所以浏览器由一个 **Chrome 扩展**接进来；同一个 Longx 可以接多个浏览器；一个项目默认关着，
要用的项目在描述里写一行 `plug Browser`。

原则（和参考实现一致：codex 的 `node_repl.js`、browser-harness、browser-use-pi 都是这个形状）：

- **一个工具、写代码**：`javascript(title, code)`，代码跑在服务器上 shim 内嵌的 JS 运行时里，
  原语（`page` / `tabs` / `snapshot()` / `screenshot()`）落到裸 CDP。没有固定动作集、没有给
  DOM 编号的启发式——模型自己在 JS 里过滤无障碍树。
- **扩展只是传输层**：白名单里的几个 `chrome.*` 调用原样转发，一行 eval 都没有（Playwright
  Extension 的形状，能上 Web Store）。
- **提示词用别人的原文**：原语和配方用 browser-use-pi 的系统提示词（MIT），什么时候要问人用
  codex 的 Computer/Browser Use Confirmation Policy（`models.json`）；只改 Longx 不同的地方。
- **边界在 Longx 这边**：哪个项目用哪个浏览器（描述文件）、哪些站点可去（每浏览器的 origins，
  首次访问问人）、几个标签（项目 `max_tabs`、浏览器总上限）。

## 1. 一句话模型

> 人的 Chrome 装了 **Longx 浏览器桥**，填 Longx 地址，Longx 里点「允许」→ 一条**连接**（一行
> `Longx.Chrome.Browser`，有名字、可起**别名**）。项目描述写 `plug Browser, browser: "qa-chrome"`
> → 这个项目的会话得到 `javascript` 工具；第一次调用时会话拿到自己的**标签组**和一个
> **JS 运行时**（`shim js`）；`page.goto(url)` 经运行时 → Elixir → 扩展 → `chrome.debugger`
> 到那个标签；截图作为图片进模型的上下文；回合结束 debugger 从标签上 detach，标签留着。

## 2. 扩展 `assets/extension/`（MV3，TypeScript + Vite）

- 权限 `debugger tabs tabGroups storage alarms`，**无** `host_permissions`，无内容脚本。
  `minimum_chrome_version: "118"`（116 起 websocket 消息、118 起活动的 debugger 会话都让
  service worker 不被回收；Phoenix 30 s 心跳就是保活；再加一个 30 s 的 alarm 兜底重连）。
- Service worker 是一个薄中继（`src/relay.ts`）：
  - **白名单命令**（位置参数数组）：`chrome.debugger.attach / detach / sendCommand`、
    `chrome.tabs.create / remove / update / get / query / group / ungroup`、
    `chrome.tabGroups.update / get / query`、`chrome.windows.update / get`。别的方法一律拒绝。
  - **转发事件**：`chrome.debugger.onEvent / onDetach`、`chrome.tabs.onCreated / onUpdated /
    onRemoved`、`chrome.tabGroups.onRemoved`。只转发和已 attach 标签、或本扩展开的标签相关的。
- **弹窗**（`popup.html`，纯 TS）：Longx 地址、连接状态（待批准 / 已连接 / 离线）、这个浏览器
  在 Longx 里的名字、正在被哪些会话用几个标签、断开。
- **配对**：扩展第一次连接不带 token，带设备信息；Longx 建一行 `pending`；人在 Settings →
  浏览器 点「允许」→ channel 推 `approved {token}` → 扩展存 `chrome.storage.local`，以后连接
  带 token，静默重连。`install_id`（扩展生成、存本地）让重连不重复建 pending 行。
- **分发**：`mix assets.build` 把扩展编到 `priv/static/extension/unpacked/` 并打成
  `priv/static/extension/longx-chrome.zip`；`GET /extension/longx-chrome.zip`
  （`LongxWeb.ExtensionController`）下载；Settings → 浏览器 的卡片给下载和三步安装说明
  （`chrome://extensions` → 开发者模式 → 加载已解压）。Web Store 上架是另一件事。

### 2.1 线协议（Phoenix channel）

Socket `/chrome/socket`（`LongxWeb.ChromeSocket`，`check_origin: false` —— Origin 是
`chrome-extension://…`；靠 token），连接参数：

```json
{"install_id": "…", "token": "…"|null,
 "device": {"name": "MJ 的 MacBook · Chrome 153", "ua": "…", "platform": "mac", "extension": "0.1.0"}}
```

Channel `chrome:bridge`，join 回复 `{"browser_id", "status": "pending"|"approved", "name"}`。
之后：

| 方向 | 事件 | 载荷 |
|---|---|---|
| 服务器 → 扩展 | `cmd` | `{"id", "method": "chrome.debugger.sendCommand", "params": [{"tabId": 12}, "Page.navigate", {"url": "…"}]}` |
| 扩展 → 服务器 | `result` | `{"id", "result": …}` 或 `{"id", "error": "…"}` |
| 扩展 → 服务器 | `event` | `{"method": "chrome.debugger.onEvent", "params": [{"tabId": 12}, "Runtime.consoleAPICalled", {…}]}` |
| 服务器 → 扩展 | `approved` | `{"token", "name"}` |
| 服务器 → 扩展 | `revoked` | `{}`（扩展忘掉 token，回到未配对） |
| 服务器 → 扩展 | `state` | `{"sessions": [{"title", "tabs": 3}]}`（弹窗显示） |

服务器侧 `Longx.Chrome.Connection.call(browser_id, method, params, timeout)`：
channel 进程按 `id` 记 `pending`，`result` 回来 `GenServer.reply`；超时 `{:error, :timeout}`；
浏览器不在线 `{:error, :offline}`。事件广播到 PubSub `chrome:<browser_id>`，
`{:chrome_event, browser_id, method, params}`。

## 3. 服务器 `Longx.Chrome`

```
lib/longx/chrome.ex                 域（Ash）；pairing / aliases / directory 的门面函数
lib/longx/chrome/browser.ex         Browser 行：install_id, name, device, status, token_hash,
                                    max_tabs (6), origins (map), last_seen_at, approved_at
lib/longx/chrome/aliases.ex         别名 → [browser_id]，默认别名；Setting `chrome_aliases`
lib/longx/chrome/connection.ex      channel 进程注册表（Registry, 按 browser_id）+ call/4
lib/longx/chrome/session.ex         每会话一个：标签组、标签、CDP 代理、策略、console 缓冲
lib/longx/chrome/runtime.ex         每会话一个 `shim js` 进程：execute / interrupt / 宿主调用
lib/longx/chrome/policy.ex          origin 检查（allow / deny / ask）
lib/longx/chrome/tabs.ex            配额：Registry 重复键 {:project, id} / {:browser, id}
lib/longx_web/channels/chrome_socket.ex, chrome_channel.ex
lib/longx_web/controllers/extension_controller.ex
lib/longx/agent/plugs/browser.ex    插件；旧的 web_fetch 插件改名 Plugs.WebFetch
priv/agent/browser/prelude.js       运行时里的原语
priv/agent/browser/prompt.md        提示词（browser-use-pi 原文改）
priv/agent/browser/policy.md        codex 的确认策略原文
native/shim/js.go                   `shim js`：goja + eventloop + JSON 行协议
```

### 3.1 配对与别名

- `Browser.status`：`pending` → `approved`（token 只在批准那一刻发一次，行里存 sha256）→
  `revoked`。同一 `install_id` 重连复用行。在线 = channel 进程在 `Connection` 注册表里。
- **别名**照 `Longx.AI.Aliases`：`Setting` `chrome_aliases` 是 `%{alias => [browser_id, …]}`，
  `chrome_default_alias` 一个名字。解析 = 列表里**第一台在线的**；一个别名两台机器就是
  「任一在线的」。解析不到 → 模型面前一条 notice（和描述里写了不存在的模型一样），工具照挂。
- 多人：仓库里的 `.longx/agent.exs` 写别名，每个人的 Longx 把别名映到自己配对的扩展。

### 3.2 会话 `Longx.Chrome.Session`

一个会话线程一个 GenServer（`:temporary`，`Chrome.SessionSupervisor` + `Chrome.SessionRegistry`
按 thread_id），第一次 `javascript` 调用时起：

- 解析别名 → `browser_id`；订阅 `chrome:<browser_id>`。
- **标签组**：第一个标签 `chrome.tabs.create({url: "about:blank", active: false})` →
  `chrome.tabs.group` → `chrome.tabGroups.update(groupId, {title: "Longx · <会话>", color})`；
  之后的标签进同一组。`tabs.list()` 只列本组的；人把标签拖出组就是收回，拖进来就是交给它
  （每次列表都按 `groupId` 重新查）。
- **配额**：`max_tabs` 按项目计（所有会话合起来，`Chrome.Tabs` 用 Registry 重复键数），
  浏览器行的 `max_tabs` 是总上限；超了 `tabs.open` 报错并说明改哪里。
- **CDP 代理** `Session.cdp(pid, target, method, params)`：
  - `target` 是 `"tab:<id>"`，标签必须是本会话的；未 attach 先 `chrome.debugger.attach(1.3)`
    并 `Runtime.enable` / `Page.enable` / `Log.enable`。
  - `Page.navigate` 和 `longx.tabs.open` 的 URL 过 `Policy`；`Target.*`、`Fetch.*`、
    `Browser.*` 拒绝（"managed by Longx"）。
  - **伪方法**（`target: "longx"`）：`longx.tabs.open {url}`、`longx.tabs.list`、
    `longx.tabs.close {id}`、`longx.console {tab, clear}`（缓冲的 `Runtime.consoleAPICalled` /
    `Log.entryAdded` / `Runtime.exceptionThrown`，每标签最近 200 条）。
- **策略** `Policy.check(browser, url)`：`origins[origin].access` allow / deny；没有 → 一个
  Ask（`Longx.Agent.ask/2`：「允许 agent 在你的 Chrome 里打开 github.com？本轮 / 这个会话 /
  一直 / 拒绝」）；「一直」写回浏览器行，「这个会话」记在 Session，「本轮」记在 Session 到
  回合结束。问人期间运行时的 cell 计时暂停。
- **回合结束**：插件的 `:turn_end` → `Session.turn_ended/1` → 所有标签 `chrome.debugger.detach`
  （横幅消失），标签保留；下一回合按需再 attach。
- **结束**：Session 监视这个线程的 `Longx.Agent` 进程；agent 退出（空闲）后 60 s 内没有新的
  agent 注册 → 关掉自己开的标签、停运行时、退出。线程归档 / 删除 → 立刻。
- 扩展断线：Session 留着；重连后 `chrome.tabs.query({groupId})` 重新对账，attach 状态清零。

### 3.3 运行时 `Longx.Chrome.Runtime` 与 `shim js`

`shim js` 是 Go shim 的子命令：goja（纯 Go）+ `goja_nodejs/eventloop`，一个持久的 realm，
JSON 行协议走 stdin/stdout（经 `Longx.Shim`）。

| 方向 | 行 |
|---|---|
| 宿主 → shim | `{"type":"execute","id":"c1","code":"…","timeout_ms":30000}` |
| 宿主 → shim | `{"type":"interrupt","id":"c1"}`（`vm.Interrupt`，死循环也停） |
| 宿主 → shim | `{"type":"cdp_result","id":"r7","result":{…}}` / `{…,"error":"…"}` |
| 宿主 → shim | `{"type":"close"}` |
| shim → 宿主 | `{"type":"ready","engine":"goja"}` |
| shim → 宿主 | `{"type":"cdp","id":"r7","target":"tab:12","method":"Page.navigate","params":{…}}` |
| shim → 宿主 | `{"type":"log","id":"c1","text":"…"}`（console 输出，流式） |
| shim → 宿主 | `{"type":"image","id":"c1","mime":"image/jpeg","data":"<base64>"}` |
| shim → 宿主 | `{"type":"result","id":"c1","value":…,"error":null,"interrupted":false}` |

- 一个 cell = `code` 包成 `(async () => { … })()`，`await` 顶层可用；变量挂在 realm 的
  global 上跨 cell 保留。
- 宿主函数只有两个：`__cdp(target, method, params) → Promise`、`__image(mime, base64)`；
  `console.*` 走 `log` 行。其余都在 `prelude.js` 里用 JS 写。
- 超时：Elixir 计时，到点发 `interrupt`；2 s 内没回 `result` 就 `Shim.kill` 并重启（下一
  个 cell 的结果头一行说 "JavaScript state was reset"）。
- 补的宿主环境：`setTimeout / clearTimeout / setInterval`（eventloop）、`URL`、`atob / btoa`、
  `TextEncoder / TextDecoder`（prelude）。没有 `fetch`、没有 DOM、没有 `require`——提示词说明。

### 3.4 原语（`prelude.js`，模型看到的 API）

照 browser-use-pi：

```
page                         当前标签；page = await tabs.open(url) 切换
page.goto(url) → {url,title} Page.navigate，然后等 document.readyState !== 'loading'
page.info() → {url,title}
page.evaluate(fn|string, arg)  Runtime.evaluate(returnByValue, awaitPromise, userGesture)
page.waitFor(fn, arg, {timeoutMs})  轮询 evaluate，100 ms 一次
page.snapshot() → {url,title,nodes:[{id,role,name,value?,checked?,pressed?,selected?,expanded?,disabled?}]}
                             Accessibility.getFullAXTree，滤掉 ignored 和无 backendDOMNodeId 的
page.screenshot()            Page.captureScreenshot jpeg q70 → __image；一个 cell 最多 4 张
page.clickAt(x, y)           mouseMoved / mousePressed / mouseReleased
page.cdp(method, params)     这个标签上的任意 CDP
page.console({clear})        缓冲的 console / 异常 / 网络错误
page.close()
tabs.open(url) / tabs.list() / tabs.get(id) / tabs.close(id)
snapshot() / screenshot()    = page 的
```

### 3.5 插件 `Longx.Agent.Plugs.Browser`

- **不进默认管线**。`plug Browser, browser: "qa-chrome", max_tabs: 3`；`browser:` 缺省用
  默认别名，`max_tabs` 默认 1。
- `:request`：instructions = `prompt.md`（原语说明和配方）+ `policy.md`（codex 确认策略）
  + 一行「这个项目的浏览器是别名 `qa-chrome`」；工具 `javascript(title, code)`。
  不放在线状态、不放标签数——前缀要稳定。
- `javascript/2` → `Session.execute(thread_id, code, timeout: 30_000)` → `{output, images,
  value, error, reset?}`：输出截到 12k 字符，全文落 `<data>/chrome/<thread>/cells/<id>.txt`
  并给路径；图片进 `extra["images"]`（内核：`Calls` 接受 `"images"` 列表，与 `"image"` 同）；
  `details` 给页面（title、code、图片数）。
- `:turn_end` → `Session.turn_ended/1`。
- **上下文里只保留最近两个 cell 的截图**：`Transcript.input/1` 对 `kind: :screenshot` 的
  图片消息只留最后两条，更早的去掉（browser-use-pi 的 `project()`）。

### 3.6 提示词的来源

| 段 | 来源 | 改动 |
|---|---|---|
| 原语与配方 | browser-use-pi `src/prompt.ts`（MIT） | 去掉 workspace / artifact / checkpoint / finish 段；`clickAt` 等名字照旧；加一句运行时说明 |
| 何时问人 | codex `models.json` `confirmation_policies.browser_use` | 去掉 computer use、MCP connector 的句子；"Hand-off" = 在消息里说明并停下，人在自己的 Chrome 里接着做 |
| 边界 | 我们的 | 项目的浏览器别名；新站点会问人；`page.console()` 看错误 |

写之前逐段给人看。

## 4. 页面

- **Settings → 浏览器**（`BrowsersSection`）：待批准（允许 / 拒绝）；已配对列表（名字可改、
  设备、在线、几个会话在用、`max_tabs`、origins 列表可删、吊销）；别名卡（别名 → 浏览器们、
  默认别名）；扩展卡（下载 zip、版本、安装步骤、需要 Chrome 118+）。
- **项目设置**：定义卡里 `Browser` 插件出现时显示解析到哪台、是否在线（只读）。
- **聊天**：`javascript` 是一个 tool-call 行：`title`、代码折叠、输出是终端块、截图内联。

RPC（`Longx.Chrome.Bridge`，无数据资源）：`list_chrome_browsers`、`approve_chrome_browser`、
`reject_chrome_browser`、`revoke_chrome_browser`、`rename_chrome_browser`、
`set_chrome_browser_max_tabs`、`delete_chrome_origin`、`chrome_aliases`、`set_chrome_alias`、
`delete_chrome_alias`、`set_chrome_default_alias`、`chrome_extension`（下载地址、版本）。
页面每 3 秒重新拉一次列表（`useChromeBrowsers`：在线、在用的标签页都是活的状态）；`Longx.Notify`
一条 `approval` 事件通知有浏览器请求接入。

## 5. 测试

- Go：`native/shim/js_test.go`——execute 的值、console 流、`__cdp` 往返（假宿主）、interrupt
  停下死循环、超时后状态重置。
- Elixir：`test/longx/chrome/runtime_test`（真 `shim js`，假 CDP 处理函数）、
  `session_test` + `chrome_channel_test`（假扩展：一个测试进程 join channel，按脚本答 `cmd`）、
  `browsers_test`（配对、别名）、`test/longx/agent/plugs/browser_test`（Bypass 当模型 + 假扩展，
  `javascript` 端到端，`:turn_end` detach，截图进上下文并只留两张）、`chrome_rpc_test`、
  `extension_controller_test`。
- TS：扩展中继的单元测试（假 `chrome` 对象）。
- e2e `11-chrome`：playwright 以 `--load-extension` 起 Chromium，配对、批准，项目
  `local/agent.exs` 写 `plug Browser`，让 agent 打开 harness 起的本地页面并读标题。

## 6. 分期

1. **本分支**：扩展 + 配对 + 中继；`shim js` + 运行时 + 会话 + 标签组 + 配额 + origins 询问；
   `javascript` 工具与提示词；截图只留两张；Settings → 浏览器（含下载）；测试与 e2e。
2. Fetch 拦截强制域名策略（重定向、链接也拦）、跨域 iframe（`sessionId`，Chrome ≥125）、
   对话框、下载、上传、`browser.waitFor(event)`、Web Store 上架。
3. 服务器自带 headless Chrome（同一传输 behaviour）、`fillSecret` 接 `Longx.Credentials`。
