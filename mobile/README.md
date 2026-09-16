# Longx 手机端

Expo（React Native）应用，和 web 端共用 `../assets/js/core`——RPC 客户端、socket、codex 事件到消息的折叠、
assistant-ui 的 runtime 都是同一份代码（Metro 把 `@/core/*` 指到 web 端，`@assistant-ui/react` 指到
`@assistant-ui/react-native`）；`js/ui/` 那 17k 行 DOM 代码在这里由原生界面代替，只有代码编辑器和 diff
借 web 端的 `/embed/*` 页面在 WebView 里跑。

- 首次启动配对：电脑上 Longx → 设置 → 移动端，地址 + 六位配对码 → 设备令牌（`Longx.System.Device`），
  之后每个请求带 `Authorization: Bearer`。
- 页面：项目（含"正在进行"）→ 会话列表 → 会话（assistant-ui 原生 Thread + 我们的 codex 渲染器：命令、改动、
  搜索、审批卡、提问、子 agent；输入框旁的访问模式 / 模型 / 思考档位是底部弹层）→ 文件 / Git / 历史 / 设置。
- 通知：Android 前台服务（`modules/longx-notify`，Kotlin Expo module）常驻一条到 `notify` channel 的连接，
  等待审批 / 完成 / 出错各发一条通知，点开直达会话（`longx://` 深链接），不依赖 FCM。
- 更新：从 longx 仓库的最新 Release 里找 `.apk`，下载后交系统安装（同一把 key 签，能覆盖）。

## 开发

    npm install
    npx uniwind generate-artifacts --css ./global.css --dts ./uniwind-types.d.ts   # className 的类型
    npm run check                # tsc + jest
    npx expo export --platform android --output-dir /tmp/x    # 只打 JS 包，查引用
    npx expo prebuild --platform android --no-install && cd android && ./gradlew assembleDebug

本机没有 JDK 时 `JAVA_HOME=~/.gradle/jdks/<gradle 下载的 17>`；`ANDROID_HOME` 指向 SDK（platform 35）。
`android/`、`ios/` 是 prebuild 生成的，不入库。发布 key：环境里放 `LONGX_KEYSTORE` / `LONGX_KEYSTORE_PASSWORD` /
`LONGX_KEY_ALIAS` / `LONGX_KEY_PASSWORD`（`plugins/withReleaseSigning.js` 读），没有就用 debug key。
版本号来自 `LONGX_VERSION`（Release 工作流传 tag），和服务器同一个。

Web 导出（react-native-web）能在浏览器里跑同一套界面，用来在没有模拟器的机器上看效果：
`npx expo export --platform web`，静态起一个服务，Chromium 加 `--disable-web-security`（跨域）。
