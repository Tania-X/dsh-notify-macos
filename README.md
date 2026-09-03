# dsh-notify-macos

DeepSeek Harness 插件：每次对话/任务完成后，在 MacBook 屏幕右上角弹出**常驻悬浮通知卡片**，点击卡片即可**跳转到完成该任务的会话**（跨 Session 精确跳转），让你即使切到后台也能第一时间回到任务现场。

## 行为

- 每个会话的对话轮次处理完毕时（agent `running → idle`），弹出一张编号卡片，悬停在右上角，直到你处理。
- **卡片标题 = 会话名**（如「DeepSeek插件任务完成提醒」），正文 = 「任务完成，点击查看详情」——一眼知道是哪个会话完成了。
- **点击卡片** → 浏览器画面切到该会话并滚到最新消息（任务完成处），**无页面刷新**。
- **向右拖拽卡片** → 直接清除。
- **多任务同时完成**：多张卡片带递增编号堆叠，可分别处理。

## 消息链路

```
DSH host (Node 进程)
│
│ 1. 插件监听 agent/status：running → idle 即一轮对话完成
│
│ 2. 插件经 Unix socket 向守护进程推送一条 show 指令
│    └─ socket: $TMPDIR/dsh-notify-macos.sock
│    └─ 载荷: { sessionId, sessionTitle, message, action:"jump-web" }
│
▼
dsh-notify-server (Swift/AppKit 守护进程)
│
│ 3. 守护进程在屏幕右上角绘制编号悬浮卡片
│    └─ 标题 = sessionTitle（会话名）；正文 = 完成文案
│    └─ 卡片常驻，等待点击或右拖
│
│ 4. 用户点击卡片 → BrowserJumper 接管
│
▼
浏览器 (Safari / Chrome / Edge / Brave / Arc / Opera / Firefox)
│
│ 5. 守护进程先探测哪个浏览器已打开 DSH Web UI（只枚举标签页，不执行 JS）
│    └─ 只在承载 GUI 的那个浏览器实例内操作，绝不跳去别的浏览器
│
│ 6. 向 GUI 标签页注入 JS，优先“原地切换”：
│    └─ 按 sessionTitle 精确/模糊匹配侧边栏会话行（role="treeitem"）
│    └─ 匹配成功 → 模拟点击该行 → GUI 切到目标会话并滚到底部（无刷新）
│
│ 7. 边界回退（会话刚被删除/归档，行不可见）：
│    └─ 清除持久化会话选择并刷新 → GUI 自动落到第一个可用 Session
│    └─ 一个 Session 都没有 → GUI 显示空状态/新建会话视图
│
│ 8. 若 JS 注入被拒绝（浏览器未授权）：
│    └─ 至少聚焦 GUI 标签页（open location 激活既有标签，不新开窗口）
│    └─ 若没有可脚本化浏览器 → 用系统默认方式打开 GUI
```

## 组件

| 组件 | 位置 | 职责 |
| --- | --- | --- |
| Cordis 插件 | `lib/index.js`（host 进程内） | 监听完成事件，经 socket 推送给守护进程 |
| Swift 守护进程 | `bin/dsh-notify-server` | 自绘悬浮卡片；点击后控制浏览器跳转 |
| Web profile 注册 | `$DSH_HOME/profiles/web/cordis.patch.yml` | 加载插件（HMR 热更新） |

守护进程不可用时，插件回退到 `osascript` 弹一次系统通知，保证完成不被静默丢弃。

## 安装

插件已安装到 web profile 并热加载：

```
$DSH_HOME/profiles/web/plugins/dsh-notify-macos/lib/index.js
$DSH_HOME/profiles/web/plugins/dsh-notify-macos/bin/dsh-notify-server
$DSH_HOME/profiles/web/cordis.patch.yml   # notify-macos 条目
```

验证加载状态：

```bash
curl -s -X POST http://127.0.0.1:3080/api/pluginInventory/list \
  -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v1","method":"pluginInventory/list","payload":{"args":{}}}'
# 应看到 include:notify-macos ... active
```

验证守护进程：

```bash
ls -l $TMPDIR/dsh-notify-macos.sock
echo '{"cmd":"ping"}' | nc -U $TMPDIR/dsh-notify-macos.sock   # → {"ok":true}
```

## 配置

在 `cordis.patch.yml` 的 `notify-macos.config` 中修改：

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | 总开关 |
| `title` | string | `"DeepSeek Harness"` | 无会话名时的兜底标题（正常显示会话名） |
| `message` | string | `"任务完成，点击查看详情"` | 卡片正文 |
| `sound` | boolean | `false` | 完成时是否播放提示音 |
| `rootOnly` | boolean | `true` | 仅顶层会话完成时通知（`false` 则子代理完成也通知） |
| `clickAction` | string | `"jump-web"` | 点击行为：`jump-web`（跳会话）/ `open-folder` / `open-web` / `none` |
| `webUrl` | string | `"http://127.0.0.1:3080"` | Web UI 地址 |
| `autoDismissSec` | number | `0` | 卡片自动消失秒数（`0` 常驻） |
| `socketPath` | string | `$TMPDIR/dsh-notify-macos.sock` | 与守护进程通信的 socket |
| `serverPath` | string | 插件包内 `bin/dsh-notify-server` | 守护进程路径 |

## 一次性授权

跨会话跳转依赖守护进程控制浏览器，需要两项一次性授权：

1. **macOS 自动化**：首次点击卡片时系统弹窗「dsh-notify-server 想要控制 Google Chrome / Safari」→ 点**允许**。
2. **浏览器允许 AppleScript 执行 JS**：
   - Safari：设置 → 高级 → 开启「显示开发菜单」→ 开发 → 勾选「允许 JavaScript 从 Apple Events」
   - Chrome：菜单 View → Developer → 勾选 **Allow JavaScript from Apple Events**

验证授权：

```bash
echo '{"cmd":"probe"}' | nc -U $TMPDIR/dsh-notify-macos.sock
# → {"ok":true,"chrome":true,"safari":true}
```

未授权时点击会退化为「聚焦 GUI 标签页」（不精确跳会话）。

## 开发

```bash
cd bin
swiftc -O dsh-notify-server.swift -o dsh-notify-server   # 重新编译守护进程
```

Socket 协议（JSON Lines）：

| 命令 | 载荷 | 说明 |
| --- | --- | --- |
| `show` | `{sessionId, sessionTitle, title, message, action, url, sound, autoDismissSec}` | 弹卡片 |
| `ping` | — | 存活探测 → `{"ok":true}` |
| `probe` | — | 浏览器授权探测 → `{"ok":true,"chrome":…,"safari":…}` |
| `debug` | `{url, sessionId, sessionTitle}` | 手动触发一次跳转（诊断用） |

## 平台要求

- 仅 macOS（插件按 `process.platform === "darwin"` 判断）。
- 守护进程需 Swift 5.9+ 编译（已随包提供预编译二进制）。
- 踩坑记录见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 同类项目与社区参考

本插件是独立开发的作品。联网调研确认社区已有多个功能相近的 DSH 通知插件，官方（deepseek-ai/deepseek-harness）暂未内置任务完成通知，但官方「一切皆插件」架构明确留白给社区。以下对比供后续迭代参考：

| 项目 | 平台 | 通知形态 | 会话跳转 | 说明 |
| --- | --- | --- | --- | --- |
| 本插件 | macOS | 右上角自绘悬浮卡片（常驻/拖拽清除/品牌鲸鱼） | AppleScript 注入（localStorage + 侧边栏点击） | 不依赖改动前端即可跨会话跳转 |
| [dsh-niao-message](https://github.com/dsh-niao/dsh-niao-message) | macOS | 系统通知中心横幅 | 点击直达应用（`open -a`） | 三大场景 + 回页面自动清空 + 防打扰 |
| [TARS-snail/dsh-notify](https://github.com/TARS-snail/dsh-notify) | Linux/桌面 | 桌面通知 | — | **presence 检测**：仅用户离开会话时才通知 |
| [dsh-notify-yimit](https://github.com/YiMlT/dsh-notify-yimit) | Windows | 系统通知 + WPF 自绘浮窗 | **URL hash 深链 + client half**（`#…/session=<id>` → `ctx.sessions.open`） | 与本品定位最接近；标题=会话名、多场景、常驻宿主 |
| [hotpot-labs/dsh-notifier-plugin](https://github.com/hotpot-labs/dsh-notifier-plugin) | mac/win/linux | 浏览器 `Notification()` / Tauri | — | 轻量「只通知不交互」，多后端可插拔 |
| [THEWOLFWALKER/dsh-notifier](https://github.com/THEWOLFWALKER/dsh-notifier) | 跨平台 | IM 推送 | — | 统一 `notify()` + 8 通道（telegram/bark/feishu…） |

生态汇总清单：[awesome-deepseek-harness](https://github.com/Dominic789654/awesome-deepseek-harness) · [awesome-dsh-plugin](https://github.com/Anil-matcha/awesome-dsh-plugin) · [dshworks/awesome-dsh-plugins](https://github.com/dshworks/awesome-dsh-plugins)

**最有价值的参考**：`dsh-notify-yimit` 的会话跳转走 **URL hash 深链 + 客户端 half**——由浏览器端监听 hash 后调用前端原生 `ctx.sessions.open(id)`。相比本品的 AppleScript 注入：无需 macOS 自动化权限、无需浏览器「Allow JavaScript from Apple Events」、天然无刷新、跨浏览器一致。代价是需要打包 `dsh.client` 客户端 half（社区插件已证明这是 DSH 一等公民机制）。若后续要"做正"跳转层，可优先吸收该方案，替换掉最脆弱的注入部分，同时保留本品的悬浮卡片形态。

## 后续拓展（TODO feed）

当前实现是"能跑的单体"，以下扩展点按价值排序，**等出现第二个消费者 / 跨平台需求时再逐个落地**，避免提前抽象：

### 1. `BrowserDriver` 协议（最优先）
现在 Safari 与 Chromium 家族（Chrome/Edge/Brave/Arc/Opera）的差异散落在 `probeScript` / `injectScript` 的 if/else 里。抽成协议后，浏览器列表变为驱动注册表，新浏览器只需注册一个驱动：

```swift
protocol BrowserDriver {
    var displayName: String { get }
    func findTab(matching url: String) -> Bool
    func evaluateJavaScript(_ script: String) -> Result<String, Error>
    func activate()
}
struct SafariDriver: BrowserDriver { ... }     // AppleScript "Safari" 方言
struct ChromiumDriver: BrowserDriver { ... }   // 共享，仅 appName 参数化
```

### 2. `ScriptRunner`（进程/宿主抽象）
现在硬编码 `/usr/bin/osascript`（`Process`）。同一跳转协议将来可跑在 `osascript -l JavaScript`（JXA）、进程内 `NSAppleScript`、或 **Firefox 的 DevTools Protocol**（Firefox 没有 AppleScript tab 注入，是当前唯一不支持的浏览器，RDP 是其出路）。抽协议后逻辑可 mock 可单测。

### 3. `CompletionPresenter` 门面（渲染端策略化）
渲染侧目前只有自绘悬浮卡片一种实现（+ 插件侧 osascript 兜底）。抽协议可支持 headless、日志模式、未来 Linux/Windows 通知：

```swift
protocol CompletionPresenter {
    func present(_ request: ShowRequest)
    func dismiss(id: String)
}
```
`NSWindow`/`NSScreen` 调用集中在实现里——真正的"OS 扩展点"。

### 4. 把 GUI 知识从守护进程剥离（协议演进方向）
`inPlaceScript` 硬编码了 DSH 前端的 DOM 结构（`[role="treeitem"]`、`[data-conversation-scroll]`）。更干净的形态：**插件在 `show` 消息里下发跳转脚本/URL**，守护进程退化为纯执行器。好处：前端改版只改插件；守护进程可通用化服务其他 Harness。

> **社区已验证的替代路径**：参考 [dsh-notify-yimit](https://github.com/YiMlT/dsh-notify-yimit) 的 **URL hash 深链 + client half** 方案——跳转由浏览器端监听 `#…/session=<id>` 后调用前端原生 `ctx.sessions.open(id)` 完成，守护进程完全不碰 DOM，也无需 macOS 自动化/浏览器 JS 授权。若重新设计跳转层，这是首选方向（详见上方「同类项目与社区参考」）。

### 5. 协议层现代化
- `show` 的 `cmd` 字段冗余（switch 后构造恒为 "show"）
- 手拼 JSON 回复 → Codable 枚举 + 类型化回复
- 增加协议 `version` 字段，支持平滑迁移

### 6. 进程生命周期管理（守护进程探活）
守护进程由插件 detached spawn，插件只在加载时 pre-warm 一次，不周期性探活。可加：守护进程心跳上报 / 插件定时 ping 失败自动重启 / 退出时清理 socket。

