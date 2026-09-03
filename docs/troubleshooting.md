# 踩坑记录（Troubleshooting Notes）

本文件记录开发 dsh-notify-macos 过程中遇到的真实问题与排查过程，供后续维护参考。README 只描述最终状态，本文件记录"为什么这么做"。

## 1. 为什么不用系统通知，而要自绘悬浮卡片

`osascript -e 'display notification …'` 的系统通知会在数秒后自动消失，且无法自定义拖拽手势。需求要求卡片**常驻**直到用户拖拽或点击，因此改用 Swift/AppKit 无边框窗口自绘，置顶于所有空间（`level = .statusBar`，`collectionBehavior` 含 `.canJoinAllSpaces` / `.fullScreenAuxiliary`）。

## 2. AppleScript 字符串转义：单引号是错的

最早生成的 AppleScript 里用单引号包字符串，`osacompile` 报 `Expected expression but found unknown token (-2741)`。**AppleScript 字符串字面量必须用双引号**；内嵌的 JavaScript 才用单引号。最终采用双层转义：

- `asString()`：输出 AppleScript 双引号字符串（转义 `\` 与 `"`）
- `jsString()`：输出嵌入 JS 的单引号字符串（转义 `\` 与 `'`）

## 3. schemastery 没有 `.enum()` 和 `.optional()`

插件的 Config 用了 `z.enum([...])` 和 `z.string().optional()`，运行时报 `z.enum is not a function` / `z.string(...).optional is not a function`。

- 枚举改用 `z.union([z.const("a"), z.const("b")])`（DSH 代码库内的标准写法）。
- schemastery 字段默认即可选（只有显式 `.required()` 才必填），直接去掉 `.optional()`。

## 4. Safari「Allow JavaScript from Apple Events」权限缺失

现象：点击卡片只聚焦浏览器，不跳转。守护进程日志显示：

```
Safari: You must enable 'Allow JavaScript from Apple Events' in the Developer
        section of Safari Settings to use 'do JavaScript'. (8)
```

`do JavaScript`（Safari）和 `execute targetTab javascript`（Chrome）都需要浏览器侧单独授权，与 macOS「自动化」授权是两回事。开启路径：

- Safari：设置 → 高级 →「显示开发菜单」→ 开发 →「允许 JavaScript 从 Apple Events」
- Chrome：View → Developer → Allow JavaScript from Apple Events

排查时新增了 `probe` 命令探测浏览器是否可脚本化，以及守护进程把每次 osascript 的退出码/stderr 写入 `/tmp/dsh-notify-macos.log`，否则只能盲猜。

## 5. 浏览器选择：先探测“谁开着 GUI”，而不是固定 Chrome/Safari

早期实现固定先试 Chrome 再试 Safari，导致用户明明在用 Safari，却被带到 Chrome。改成：候选列表遍历（Safari / Chrome / Edge / Brave / Arc / Opera / Firefox），**只枚举标签页 URL**（不执行 JS）找到承载 GUI 的浏览器，然后只在那个实例内操作。

注意：探测脚本里"找不到标签页"必须显式 `error "dsh-no-tab"` 让 osascript 退出非 0，否则脚本静默成功（退出 0）会被误判为"该浏览器开着 GUI"。

## 6. 会话行点击：标题匹配用「精确 → 包含」两段

注入 JS 用 `document.querySelectorAll('[role="treeitem"]')` 拿到侧边栏会话行，行内 `textContent` 除标题外还带时间等文本，所以先精确匹配、失败再用 `indexOf` 包含匹配。注入脚本返回 JSON 诊断（`{switched, rows, matched, scroller}`），由守护进程写日志，失败原因可读而不是靠猜。

## 7. 滚动容器选择器

早期用 `[data-dsh-scrollport]` 等泛化选择器找不到滚动容器，会话切换后不滚到底。前端源码里聊天滚动容器是 `[data-conversation-scroll]`（`scrollerOf()` 实现），改用该选择器并兜底查找最近的 scrollable 祖先。

## 8. 会话标题≠用户输入

调试时手动推送测试卡片用了会话里的用户消息文本（如"测试下"）当 `sessionTitle`，而 DSH 自动生成的会话标题是另一回事（如「DeepSeek插件任务完成提醒」），导致侧边栏匹配失败。真实链路中 `ctx.sessionTitle.get()` 返回的就是侧边栏显示的标题，匹配不应失败；手动构造测试载荷时必须用真实标题。

## 9. HMR 重载插件模块的坑

- `cordis.patch.yml` 的配置变更会触发 HMR 重载，但**插件模块文件本身改了不会自动重载**——loader 只在 entry 的 `name` 变化时才重新 `import`。改代码后需把 `name` 里的 `?v=N` 版本号 +1（且再改一个 config 值强制 diff，因为有时纯 name 变更不触发）。
- 守护进程 `dsh-notify-server` 是独立进程，不受 HMR 影响：替换二进制后需 `pkill -f dsh-notify-server` 再让插件重新拉起（或手动重启）。

## 10. 守护进程存活与 socket 清理

守护进程由插件 spawn（detached），插件只在加载时 pre-warm 一次，不会周期性探活。若守护进程被杀会留下 stale socket 文件，`sendToDaemon` 连接失败后插件会重新 spawn（`daemonProcess === null` 判断），但若模块级变量已非 null（同一次加载内），可能不自动恢复——手动 `rm -f $TMPDIR/dsh-notify-macos.sock && pkill -f dsh-notify-server` 后触发一次事件即可。

## 11. fallback 语义：会话被删/归档后怎么办

需求：若目标会话在完成任务后立刻被删除/归档，侧边栏匹配必然失败。此时**不应** reload 到"可能已不存在的 sessionId"（localStorage 指向无效会话），而是清除持久化选择（`localStorage.removeItem('dsh.sessions.current')`）再刷新，让 GUI 按自身默认策略落到第一个可用 Session；一个 Session 都没有则显示空状态/新建会话视图——这是诚实的下限，不做无意义的跳转。

## 12. 沙箱环境无法验证浏览器控制

开发/调试进程若在受限沙箱（如无 GUI 会话、无 TCC 授权的 bash）里跑 osascript 控制浏览器，会一律报 `-10004 权限违例`——这**不代表**用户环境（守护进程由用户 GUI 会话启动）也会失败。排查必须以用户真实点击 + 守护进程日志为准，沙箱里只能验证 AppleScript 语法（`osacompile`）和 JS 语法（`node --check`）。

## 13. `URL of t`（枚举标签 URL）与 `execute javascript` 权限不同

- 探测"哪个浏览器开着 GUI"用标签页 URL 枚举即可（`repeat with t in tabs of w … if URL of t starts with …`），不需要 JS 权限。
- 注入跳转脚本才需要浏览器侧「Allow JavaScript from Apple Events」。
- 两者都受 macOS「自动化」授权约束；分步排查可先用只读 probe 缩小范围。
