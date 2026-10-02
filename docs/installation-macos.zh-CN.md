# Mac 原生安装指南

[返回首页](../README.zh-CN.md) · [其他平台与部署方式](installation.md)

适用于 macOS 14 或更新版本、Apple Silicon（M1/M2/M3/M4 等）机器。
不支持 Intel Mac，也不要在 Rosetta 模式的终端中安装。
从 **v0.2.106** 起，Mac 原生发行包使用 **Developer ID Application 正式签名，
并通过 Apple 公证**；v0.2.104、v0.2.105 仅有临时签名。

## 1. 检查环境

在「终端」运行：

```sh
sw_vers -productVersion
uname -m
python3 --version
```

架构应为 `arm64`，Python 需要 3.9 或更新版本。Python 仅用于安装，
Longx 运行时不需要它。没有 Python 时，可通过 python.org 或已有的 Homebrew 安装。
发行包自带 Erlang 运行时、前端及原生依赖，不需要 Elixir、Node、Go 或 Docker。
Git 工作区功能另需机器上安装 `git`。

## 2. 下载并安装

打开 [v0.2.106 发布页](https://github.com/mjason/longx/releases/tag/v0.2.106)，
下载附件 `install-macos.py`，检查脚本内容，然后运行：

```sh
cd "$HOME/Downloads"
python3 install-macos.py 0.2.106
```

不要使用 `sudo`。安装器会下载 `darwin-arm64` 包及其 SHA-256 文件，
验证校验和、压缩包路径和链接，再安装到 `~/.longx`。
它创建用户级 LaunchAgent `com.longx.agent`，安装后启动，并在你登录 Mac 时自动启动。

安装完成后打开 <http://localhost:7788>，在「设置 → Provider」配置模型，
再添加项目的工作目录。服务默认仅监听 `127.0.0.1`，其他机器不能直接访问。
Provider 密钥请在设置中填写，不要发到聊天里。

## 3. 签名与安全

构建流程为所有原生 Mach-O 文件签名，并在 Apple 公证结果为 `Accepted` 后才发布 Mac 包。
这证明发布者身份与公证状态，不代表 Longx 的命令受到沙箱限制：
agent 仍以你的系统用户权限运行。需要隔离时请使用独立环境。

当前发行形式是 tar.gz，不是可附加公证票据的 DMG/PKG；Gatekeeper
可能需要联网查询 Apple 的公证记录，不能保证离线验证。
安装器不会清除 quarantine，也不会关闭 Gatekeeper。
遇到系统安全拦截时，请保留错误信息并反馈，不要关闭系统保护。

需要检查已安装的原生签名时，可运行：

```sh
codesign --verify --strict "$HOME/.longx/app/erts-"*/bin/beam.smp
codesign -dv --verbose=4 "$HOME/.longx/app/erts-"*/bin/beam.smp
```

应包含 `Authority=Developer ID Application:`、`TeamIdentifier` 和 hardened runtime 标记。
这只检查该文件的签名；发行版全量签名和 Apple 公证由 CI 检查。
同一发布页下载的 SHA-256 能发现损坏，但不是独立的发布者身份证明。

## 4. 升级与备份

Mac 暂不支持网页自升级。下载新版安装器并重跑，或不指定版本安装最新版：

```sh
python3 install-macos.py
```

升级前结束正在执行的任务。安装器停服务后备份数据，旧程序和数据快照保留在
`~/.longx/backups`；交换程序或注册服务失败时尝试恢复旧程序。
服务注册成功不等于应用健康，请检查网页和日志。
数据库迁移不会因恢复旧程序自动撤销，回退时需要匹配的数据备份。

日常备份整个 `~/.longx/data`，尤其保留 `cloak_key` 与 `secret_key_base`；
丢失加密密钥会导致已有凭据无法解密。项目文件不在这个数据目录中，需要另行备份。

## 5. 日志与服务管理

网页打不开时，先检查日志：

```sh
tail -n 80 "$HOME/.longx/logs/stderr.log"
tail -n 80 "$HOME/.longx/logs/stdout.log"
launchctl print "gui/$(id -u)/com.longx.agent"
```

停止和重新启动：

```sh
launchctl bootout "gui/$(id -u)/com.longx.agent"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.longx.agent.plist"
```

不需要输入 Mac 登录密码给 Longx 或 agent。反馈日志前检查并删去密钥等敏感信息。

## 6. 自定义安装

```sh
LONGX_HOME="$HOME/apps/longx" LONGX_PORT=8080 python3 install-macos.py 0.2.106
python3 install-macos.py 0.2.106 --no-service
python3 install-macos.py --tarball /path/to/longx-0.2.106-darwin-arm64.tar.gz
```

`LONGX_HOME` 必须是你 home 下的绝对路径；使用自定义路径时，上面的日志与签名检查路径也要相应修改。
本地 tar.gz 旁边必须有同名 `.sha256` 文件。
`--no-service` 会停止已有托管服务，安装后不启动，并非保持旧服务继续运行。

## 7. 更新浏览器插件

在 Longx「设置 → 浏览器」下载新版插件，解压到固定目录。
在 Chrome 的 `chrome://extensions` 开启开发者模式，首次选择「加载已解压的扩展程序」。
升级时替换原目录文件，再点击该插件的「重新加载」，避免重复安装导致设备身份变化。
v0.2.106 内含插件 **0.1.2**，修复名称栏布局，以及空地址仍能点击连接的问题。

插件中填写 Longx 地址（本机默认 `http://localhost:7788`），设置设备名称后连接，
再到 Longx「设置 → 浏览器」允许接入。设备名称与项目的浏览器别名是两回事：
项目需要选择对应设备的别名，agent 才会使用它。
