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

## 14. 跨桌面点卡会把“原桌面”的浏览器窗口抬到最前（已知，未根治）

### 现象

GUI（Safari）在桌面 A，用户在看 md 文档（Typora）的桌面 B 上点击悬浮卡片后：屏幕自动切到桌面 A 处理事件；滑回桌面 B 时，**Safari 在桌面 B 上本来就有的窗口**（例如一个 GitHub 标签页窗口）盖在了 Typora 之上。多桌面用户每次跨桌面点卡都要手动点一下 Typora 恢复。使用上有不便，但可接受，已记录待修。

### 排查过程（结论先行）

1. 卡片 `.canJoinAllSpaces` 全桌面可见，跨桌面点卡是常态路径。
2. 读 `com.apple.spaces` 拿到每个桌面的窗口 id 集合，配合 CGWindowList 的 owner 名，确认：桌面 A 有 Safari GUI 窗口（`DeepSeek…— DeepSeek Harness`），桌面 B 同时有 Typora **和另一个 Safari 窗口**（GitHub）。关键前提是**同一个浏览器应用在两个桌面都有窗口**。
3. 实验一：从桌面 A 激活 Safari，桌面 B 的层叠（CGWindowList 相对序）不变 → 激活的“抬升”作用在**当前桌面**。
4. 实验二（用户复现）：在桌面 B 点卡 → 屏幕**自动切**到桌面 A（程序化激活会跨桌面切换），且桌面 B 的 Safari 被抬到 Typora 之上 → 激活时先把“当前桌面（=桌面 B）”上该应用的窗口抬到最前，再切换桌面。
5. 实验三：从桌面 A 激活 Typora（窗口只在桌面 B）→ 用户被**带回**桌面 B。⇒ 任何“事后把原应用抬回去”的 undo 方案都会把用户拽回原桌面，不可行。
6. 已尝试但**无效**的修复（commit `1062279`）：把 AppleScript `activate` 换成 `NSRunningApplication.activate(options: [])`（Big Sur 后“只激活不全抬”的现代语义）。用户复现仍被抬 —— macOS 26 上无论哪种激活，都会先在当前桌面抬升该应用窗口再切换，无法用选项关掉（`.activateIgnoringOtherApps` 在 macOS 14+ 已废弃无效果）。

### 建议修复（未实现）：锚点两步切换

干净修法不是“事后恢复”，而是**切换前不让目标应用的窗口出现在当前桌面**：

1. 点卡 → 确认托管窗口**不在当前桌面**（用 CGWindowList `.optionOnScreenOnly` + AppleScript 拿到的托管窗口 bounds 判断是否在屏）；
2. 若不在 → 先激活一个“窗口只存在于 GUI 桌面的应用”（锚点）：它没有窗口在其他桌面，激活它只会把用户切到 GUI 桌面、**不抬升任何原桌面窗口**（实验已验证：激活桌面 A 独有的“提醒事项”即可无副作用切过去）；
3. 此时当前桌面 = GUI 桌面 → 再正常激活浏览器，抬升只落在 GUI 桌面；
4. 兜底：找不到可靠锚点（GUI 桌面只有浏览器窗口等）→ 退回现在的直接激活。

技术要点：锚点 = 从 `com.apple.spaces` 的窗口归属集合里找“窗口只出现在 GUI 桌面所在集合、且 owner ≠ 浏览器”的运行中应用；owner 用 CGWindowList 拿（无需录屏权限的是 owner 与 bounds，窗口标题才需要）。该 plist 结构随 macOS 版本有差异，需 try/降级。若 GUI 桌面恰好只有浏览器窗口，则无锚点可用——可考虑退化为“接受现状”或提示用户。

### 用户侧临时缓解

跨桌面点卡后回到原桌面，若浏览器窗口盖住了正在用的应用：点一下该应用的 Dock 图标即可恢复层叠（无需改任何代码）。

## 15. SwiftPM 化之后的环境/构建坑（L2 拆分后）

daemon 从单文件（`bin/dsh-notify-server.swift` + `swiftc`）改为 SwiftPM 双 target 后（见 `docs/l2-swiftpm-split.md`），记录三个新踩坑点：

1. **沙箱/受限 shell 里 `swift build` 报 `Operation not permitted`**：SwiftPM 的 manifest 缓存写 `~/Library/Caches/org.swift.swiftpm`，clang module cache 写 `/var/folders/…/C/clang/ModuleCache`——都在工作区外，文件沙箱挡得住。`swiftc` 单文件时代可用 `-module-cache-path <工作区内路径>` 规避；**SwiftPM 的 manifest 编译步无法重定向该路径**（`-Xcc -fmodules-cache-path` 只作用于 target 编译），只能给足权限或在 CI 上构建。
2. **Command Line Tools 没有 XCTest**：`swift test` 会报 `error: XCTest not available`（且 `xcrun --show-sdk-platform-path` 失败）。Core 的测试套件需完整 Xcode 或 CI（macOS runner 自带 Xcode）。全绿证据由 `.github/workflows/tests.yml`（随 PR #4 进入 main）的 `swift tests (XCTest)` job 提供；CLT 本机只能 `swift build` 验证编译。
3. **产物路径变了**：`swift build -c release` 产物在 `.build/release/dsh-notify-server`，需 `cp` 到 `bin/dsh-notify-server`（插件 `serverPath` 默认指向包内 `bin/`）。仓库内 `bin/dsh-notify-server` 是提交的二进制产物，源码在 `Sources/`（`bin/*.swift` 已移除）。

## 16. 点卡跳转「有时灵有时不灵」—— 排查笔记（2026-09-10，思考中）

### 现象
- blocked 类真实事件（审批/ask_user_question）点卡后**时而**能跳转定位、**时而**“点了一点反应都没有”（卡片会消失）；无法稳定复现。
- 一次明确观测：卡片消失、daemon 日志确认已执行 `navigated tab in Safari`（PR #7 深链修复在跑），但**视觉上只把“当前桌面”的 Safari 带到了前台，没有切到 GUI 所在桌面的 Safari** —— 指向 §14 的跨桌面激活局限。
- 但同一现象有时又完全正常 —— 说明存在未被控制的**条件变量**，不能急着归因到 §14。

### 已知事实（证据）
1. PR #7 后 blocked 点击 = 深链跳转到卡片会话（日志 `focusOnly=false` + `navigated`），会话定位本身正确。
2. **事件就在当前会话时，深链跳到同一会话 + 滚到最新 ≈ 视觉上零变化** —— “没跳转”可能是同会话的固有隐形（我们测试几乎都在当前会话里点）。
3. 跨桌面时，macOS `activate` 只抬当前桌面该应用的窗口；当前桌面若有 Safari 窗口（如 GitHub 窗口），激活的是它，不切 GUI 桌面（§14）。
4. 聚合卡（≥2 条目）**点 header = 只展开/收起**，**点行才跳转** —— 若用户点的是 header 区域，本来就不该跳；这是“时灵时不灵”的最大嫌疑之一。

### 候选假设（按嫌疑排序，待取证）
- **H1（最可疑）：点击位置在聚合卡的 header 而非行** —— 事件多（blocked+completed 合并）后卡变聚合，点 header 无跳转是“设计如此”，但用户感知为 bug。
- **H2：事件会话 == 当前会话** → 跳转隐形（深链已执行，画面无变化）。
- **H3：跨桌面激活局限（§14）** → 从有 Safari 窗口的非 GUI 桌面点卡时，只抬当前桌面 Safari、不切 GUI 桌面。
- H1/H2/H3 可能叠加（聚合卡 header + 同会话 + 跨桌面）。

### 方法论（对无法稳定复现的 bug）
1. **列条件变量 + 建矩阵**：每次出现/不出现时记录 —— 卡是单行还是聚合？点的 header 还是行？事件会话是否等于当前 GUI 会话？点击时在哪个桌面、该桌面有没有 Safari 窗口？GUI 的 Safari 是否前台？
2. **留痕优先于复现**：加结构化日志（点击分支 header/row、卡条目数、点击时 frontmost app、GUI 窗口是否 on-screen），让下次出现时日志自动留下证据，而不是靠人复述。
3. **把交互路径脚本化/可注入**：能枚举条件（如 debug 模拟“从桌面 X 点卡”）就不依赖真人碰运气。
4. **按“消除整类歧义”改进而非“修某个复现”**：例如给 header 点击也提供明确反馈（或允许跳转）、同会话跳转给可见反馈 —— 即使复现不稳定，这些是确定性的体验改进。
5. **二分验证 H1**：下次不跳时先看卡是不是多行的聚合卡 + 点击位置；H1 若成立，代价最低。

### 待实施（若需根治跨桌面）
- §14 的**锚点两步切换**落地计划：
  1. 判定“GUI 窗口是否在当前屏”（`CGWindowList(.optionOnScreenOnly)` + AppleScript bounds ↔ CG bounds 匹配）→ 在 GUI 桌面则走现状直连，避免闪烁；
  2. 不在 → 用 `com.apple.spaces` 窗口归属定位 GUI 窗口所在 Space，挑一个“只在该 Space 有窗口的运行中应用”激活（无副作用切桌面）→ sleep ~0.4s → 再跑现有浏览器激活；
  3. 纯换算逻辑（spaces 归属 → 专属锚点集合 / bounds 匹配）抽进 `dshNotifyCore` 加 XCTest；
  4. 全程兜底：spaces 解析失败/无锚点 → 日志 + 退回现状直连。
- 实施前建议先做 H1/H2 取证（加点击分支日志），避免把精力押在 H3 上。
