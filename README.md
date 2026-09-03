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
