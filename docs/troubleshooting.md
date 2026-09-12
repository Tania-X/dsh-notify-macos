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

**补充（2026-09-11，真实事故）**：除了 socket 残留，还有**句柄残留**这个更隐蔽的坑 —— 插件用模块级 `daemonProcess` 做守卫（`if (!ok && daemonProcess === null) startDaemon()`）。当 daemon **被外部杀掉**（开发者 `pkill`、崩溃）时，句柄仍非 null，插件此后**再也不重拉**，每次通知都静默降级成 `osascript display notification`（系统通知横幅：样式不同、几秒自动消失、点不到）—— 极易误判为“卡片不见了/样式变了”。
修复：`shouldStartDaemon()`（纯函数，含 2s 节流）+ 子进程 `exit`/`error` 监听清零句柄；两次调用点（投递与前暖）都改用该判断。回归测试见 `test/host-logic.test.js` 的 "daemon respawn policy"。

> 另一个相关事实：**谁启动 daemon 决定了它的 Apple Events 授权**。macOS 把 Apple Events 归因给“责任进程”，daemon 由 `dsh web`（你从终端启动）或终端拉起时归因到**终端**并继承你勾选的授权；由**沙箱内的 agent shell** 拉起则没有授权 → 所有浏览器探测 `-10004`。所以 `-10004` 时先看 daemon 是从哪起的，别急着重装权限。

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

### Backlog（记录，未实施）
- **点击分支诊断日志**（低成本、无行为变化）：在 `CardView.mouseUp` 记录 —— 点击分支（header 展开/收起 vs 行跳转 vs 拖拽）、卡条目数、点击瞬间 `NSWorkspace.frontmostApplication`、承载窗口是否在屏。用于把「时灵时不灵」自动收敛到 H1/H2/H3，而无需稳定复现。
- 同会话跳转的可见反馈（如卡上提示/短暂高亮），消除 H2 的“隐形”困惑。
- 聚合卡 header 点击的语义再评估（是否也应提供跳转入口）。

## 17. 浏览器渠道名 + 兜底 `open`：一次“新标签重载 GUI”的复盘（2026-09-10）

症状：点卡片 → **在当前浏览器新建标签并重新加载 GUI**（看似回到最早的老问题）。

日志定位：
```
[osascript navigate-Safari] exit=1 err=…“Safari”遇到一个错误：发生权限违例 (-10004)
[osascript navigate-Microsoft Edge] exit=1 err=389:399 syntax error (-2740)
[jump] no hosting tab found; falling back to open → open exit=0
```

两个原因叠加：

1. **-10004 是启动环境问题（人为）**：daemon 由**沙箱内的 shell**（`nohup` 于受限 bash）启动时，Apple Events 被拦，Safari 探测全部被拒。带完整权限重启后立即恢复（`navigated tab in Safari`）。**教训：profile daemon 不要用沙箱 shell 启动** —— 让插件（dsh web 进程）拉起，或带完整权限启动。
2. **Edge 的 -2740 是真缺陷**：本机只装了 **Microsoft Edge Dev**，而浏览器目录用的是 stable 名字 `"Microsoft Edge"` → AppleScript 找不到该应用 → 编译报 `-2740`（用 `"Microsoft Edge Dev"` 实测可编译）。以前 Safari 第一顺位成功，此路径从未暴露。

修复（本 PR）：
- `BrowserCatalog` 改为 **family → channels**（每个渠道带自己的 AppleScript 名 + bundleId；Edge stable/Beta/Dev/Canary、Chrome stable/Beta/Canary、Brave 同理）。运行时先用 bundleId 判断**哪个渠道在跑**，再用该渠道的真实 app 名发 AppleScript；`activateApp` 也按渠道解析 bundleId。
- **兜底策略收紧**：只有当“浏览器可达但没有承载 GUI 的标签页”（GUI 确实没开）时才 `open` 深链；若本轮出现 **denied（权限被拒）**，不再 `open`（那会新开标签并重载 GUI），改为记录明确日志 + 用 `NSRunningApplication` 激活浏览器（无需 Apple Events）。
- 测试：`RunningChannelResolvesInstalledChannel`（只装 Dev → `"Microsoft Edge Dev"`；stable+Dev → 选 stable）、`ProbeOrderOnlyIncludesRunningBrowsers`、`FallbackOnlyWhenNoDenial`。

## 18. 位置索引跳转（#3）：按 turn 定位，而不是会话底部

**问题**：早期实现点击卡片只会把会话滚到**最新消息**（`pinToNewest`）。当任务完成之后用户又聊了几轮，卡片指向的“完成位置”就在上方，却被无视。

**锚点选型（实测取证）**：
- host 侧 `session/event` 事件里天然带 `data.turn`（`turn/start`、`turn/end`、`tool/call` 等）；`turn/end` 的 `data.reason.kind` 还区分了正常/异常结束。
- GUI 侧（`@deepseek-ai/dsh-client-ui-conversation`）给每个聊天行打 `data-chat-anchor-key`，**一个 turn 的最后一行是 `<n>:turn-tail<TURN>`**（实测当前会话可见 `9:turn-tail91/92/93`，而进行中的 turn 94 尚无 tail 行）。key 前缀（`9:`/`13:`/`14:`）不是 turn 号，不可自行拼装 —— 因此采用 **后缀匹配 `:turn-tail<N>`**，兜底匹配 `assistant-step<N>:`。
- GUI 没有对外暴露“滚到某锚点”的 API（锚点机制是内部用于恢复滚动位置的），所以由 client half 自己按 key 找到行再设置 `scrollTop`。

**实现**：
1. host（`lib/index.js`）：`nextTurnState`/`turnAnchorFor` 纯函数跟踪每个 session 的 `open`/`lastEnded` turn；`blocked` 用**当前打开的 turn**，其余用**刚结束的 turn**，随 show 载荷下发 `turn`；
2. daemon：`ShowRequest.turn` → 深链 `#dsh-notify-macos/session=<id>&turn=N`（`JumpLink`，Core 纯函数可测）；`turn` 随卡片快照持久化，重启后点击仍能定位；
3. client（`lib/client.js`）：解析 `&turn=`，打开会话后轮询找到 `:turn-tail<N>`（或 `assistant-step<N>:`）行，把它滚到视口约 **60%** 处（上方保留该 turn 的产出）；**找不到则回退**旧的“钉到最新”。

**测试**：Playwright harness 渲染带锚点的行，断言“滚到 turn 行且在 40–80% 视口带内、未到底部”、“turn 不存在时回退到底部”、“无 turn 时行为不变”；vitest 覆盖 turn 状态机；XCTest 覆盖 `JumpLink`（含 `turn<=0` 丢弃）与快照 `turn` 往返；`socket-smoke.sh` 断言 `turn` 落盘。

**边界**：turn 号来自事件流，若卡片创建时没有 turn（旧版本 host 或事件缺失）则行为退回“钉底部”——**永远有兜底，不会比之前更差**。

### 18.1 锚点不在渲染窗口里怎么办（补齐：点击“加载更早”）

真实 GUI 只保留**最近的一批行**（本次实测 139 行），更早的 turn 不在 DOM 里；而且它是通过**顶部按钮**（i18n `chat.loadOlder`）翻页，**不是**滚到顶部自动加载 —— 因此第一版 `scrollToTurn` 在旧 turn 上会找不到行而回退到底部。

补齐逻辑（`lib/client.js`）：
1. 找不到锚点行时，优先**点击该“加载更早”按钮**：类名做**后缀**匹配（`button[class$="_older"]` 或 `[class$="_older"] > button`；子串匹配会连 `_olderHint` 这类容器一起命中）；文案兜底只认 `\b(older|earlier)\b`、`更早`、`加载更早`（不含 `加载更多/历史`，也避免 `Folder` 这类子串），并排除 `loading/加载中`；**点击有节流**（≥500ms 一次，连续 3 次没加载出新内容就停手）；
2. 每 150ms 一个 tick，**受 8s 时限约束**；找到后进入“持续对齐直到布局稳定 3 轮”；
3. 仍未找到才回退 `pinToNewest`。

**真实 GUI 实测**（`test/manual/real-gui-anchor.mjs`，锚定一个已滑出窗口的旧 turn）：
```
BEFORE: scrollTop=7303(=max, 底部), turn-tail91 未渲染
AFTER : scrollTop=3853, scrollHeight 7303→15895（历史已翻页加载）,
        turn-tail91 在视口 386/644px ≈ 60% → inBand, 未到底部
```

### 18.2 聚合卡的锚点是**逐行**的（每行跳自己的位置）

**问题**：锚点最初挂在**卡片**上（`NotificationCard.turn`），而同一 session 的多次完成会聚合成一张卡 —— 合并时把 `turn` 覆盖成最新那次，于是展开后点**任何**一行都跳最新位置，“位置索引”在聚合卡上退化成“跳底部”。

**修法**：锚点下沉到**完成条目**（每行一个）：

| 层 | 字段 | 说明 |
| --- | --- | --- |
| host | 每帧 show 载荷的 `turn` | 本来就按事件逐次下发，无需改动 |
| Core | `CompletionEntry.turn` / `SnapshotEntry.turn` | 随行存储；`removeCompletion` 重排索引时**保留**各自的锚点 |
| Core | `CardModel.jumpTurn(forRow:cardTurn:)` | 点第 N 行 → 该行的 `turn`；该行没有（旧卡片）或行号越界（表头/空白）→ 回落卡片级 `turn`；两者都无 → `nil`（client 端继续回退“钉最新”） |
| daemon | `ShowRequest.turn` → `addCompletion(turn:)` | 合并路径也只更新**该行**，同时把卡片级 `turn` 记为最新（单行卡片/表头沿用） |
| daemon | `performAction(focusOnly:turn:)` | 行点击把该行锚点透传给 `BrowserJumper.jump`，日志 `[jump] target=… (turn=N)` 可直接看到用的是哪一行 |

**兼容性**：`turn` 是可选字段，**旧快照**（条目里没有 `turn` 键）仍能加载，那些行回落卡片级锚点 —— 升级不会清空正在显示的卡片。

**测试**：XCTest `PerRowTurnTests`（逐行独立锚点 / 重排后不丢 / 回落规则）+ 快照往返与旧文件兼容；`socket-smoke.sh` 断言合并卡落盘后是 `card=12 rows=[11, 12]`（同一 session 两帧不同 turn，各自保留）。

**边界测试夹具**：`test/manual/push-anchors.py <socket> <sessionId> <turn>[:<标签>] ...` —— 对同一 session 连推多帧、每帧一个历史 turn，聚合成一张卡；逐行点击即可验证“窗口内 / 窗口外（需翻页）/ 极早 / 不存在的 turn（应回退最新）”四个边界。

## 19. 改了 host/client 半区却没重启 `dsh web`：GUI 里跑的仍是旧代码

**现象（2026-09-12 实测）**：daemon 静默退出后**再也不回来**，卡片一直不出现；同时插件派发出来的卡片行**没有 `turn`**（位置锚点失效）。

**取证**：
- 进程：`lsof -nP -iTCP:3080 -sTCP:LISTEN` → `node /Users/apple/.dsh/node_modules/.bin/dsh web`（本次 PID 11062）；`ps -o lstart` 显示它**9月10日 01:08** 就启动了，而今天的 PR（#14 turn 跟踪、#15 daemon 自愈）是白天才合进 main 的。
- 行为：此后插件派发的行里没有 `turn` 字段（PR #14 才加的），且 daemon 死了没有触发重拉（PR #15 才加的逻辑）——与“加载的是 9月10日的 host 半区”完全一致。

**结论**：host 半区（`lib/index.js`）是**在 GUI server 进程启动时**加载并被常驻引用的，`cp` 到 profile 目录**不会**让运行中的 GUI 换代码。所以：

- 改 host 半区（事件跟踪 / 下发字段 / daemon 重拉）→ **必须重启 `dsh web`**（在自己终端里 Ctrl-C 后重跑），并刷新浏览器页面让 client 半区重新加载；
- 只改 daemon 二进制（`bin/dsh-notify-server`）→ 重启 daemon 即可，GUI 不用动；
- 只改 client 半区（`lib/client.js`）→ 刷新页面即可。

**附带的一个坑**：daemon 装在终端里用 `... &` 起（没有 `nohup`/`disown`）时，**关掉那个终端会 SIGHUP 把它带走** —— 表现为“没有 crash 报告、日志 0 字节、进程凭空消失”。重启时用：

```bash
nohup /Users/apple/.dsh/profiles/web/node_modules/dsh-notify-macos/bin/dsh-notify-server \
  /tmp/dsh-notify-macos.sock > /tmp/dsh-notify-macos.log 2>&1 & disown
```

（GUI 重启后由插件自己拉起的 daemon 挂在 GUI server 下，不会随终端退出；前提是 host 半区是含自愈逻辑的新版本。）

### 18.3 真实 GUI 的逐行锚点边界实测（client 侧，不依赖 daemon）

`test/manual/real-gui-multi-anchor.mjs` 直接对**真实 `dsh web`** 逐条发深链
（`#dsh-notify-macos/session=<id>&turn=N`），量测每一档锚点的落点 —— 不需要 daemon、不需要
macOS 自动化授权，因此可以在“卡片点击”之外独立验证 client 半区：

```bash
PLAYWRIGHT_BROWSERS_PATH=.pw-browsers node test/manual/real-gui-multi-anchor.mjs 104 98 60 20 1 9999
```

本次实测（会话 `…404c20`，视口 644px）：

| 锚点 | 结果 | 数据 |
| --- | --- | --- |
| 104（最新，窗口内） | ✅ 精确命中 | `turn-tail104` 在视口 386px ≈ 60%，未到底部 |
| 98（窗口内偏旧） | ✅ 精确命中 | 行数 253→642（翻页），386px |
| 60（窗口外，需翻页） | ✅ 精确命中 | 行数 →2019，`scrollHeight 39637→123272`，386px |
| 20（更旧） | ✅ 命中 | `scrollTop=6005`，贴近已加载历史的顶部 |
| 1（最早） | ⚠️ 回退 | 只翻到 `tailRange 15..107`，8s 时限内到不了最开头 → 回退“钉最新”（底部） |
| 9999（不存在该 turn） | ✅ 设计内回退 | 稳定后 `atBottom=true`，最新行在视口内 |

**边界语义（两档）**：
1. **会话真的有的锚点** → 落到**它自己**的 `turn-tail<N>` 行、视口 40–80% 带内（这一步也是逐行锚点功能的验收点：每行带自己的 `turn`）；
2. **取不到的锚点**（不存在的 turn，或超出翻页预算的极旧 turn）→ 回退 `pinToNewest`（最新行可见）——**永远不比加锚点之前更差**。

**已知预算**：client 的 seek 有 8s 时限 + “连续 3 次没加载出新内容就停手”。本会话从最新翻到 turn 15 就要 `rows 253→3338`、`scrollHeight 720→218168`，因此极旧锚点（如 turn 1）会在时限内放弃并回退；这不是 bug，而是“点击后不能一直僵着”的取舍。要覆盖更深的锚点就调大 `scrollToTurn` 的 `timeoutMs`（代价是点了以后停留更久）。

**探针取数要等稳定**：回退路径（`pinToNewest`）比直接命中晚落位，脚本对“无锚点”档等 12s 而不是 9s —— 否则会读到滚动中途的位置，把 9999 误判成失败（本次第一版就踩了）。

## 20. 「点了卡片它直接消失、但没有跳转」：跳转成功了，可窗口没到你眼前

**现象（用户报告，含条件）**：当 App 处于激活状态（点的是 Safari 页面）时能跳；但如果当时前台是别的 App（菜单栏显示 `文件/编辑/显示/窗口/帮助` 那一栏）→ 卡片直接消失，什么都没跳。

**排查**：日志里那些点击**全部**是“成功”的 ——
```
[jump] target=…&turn=98 (turn=98)
[jump] pass 1 probing Safari
[navigate] Safari tab updated; modern-activating
[jump] navigated tab in Safari
```
即：AppleScript **确实把托管标签页的 URL 改掉了**，但**“浏览器有没有真的到前台”这一步完全没被观测** —— 代码是 `_ = activateApp(appName)`，返回值直接丢掉、失败不记日志。于是出现“跳转逻辑跑完了 → 卡片按设计 dismiss → 用户屏幕上什么都没发生”的假成功。

更早的设计取舍是：`activateApp` 故意**不带** `.activateAllWindows`（避免把别的 Space 的窗口全抬起来压住用户正在用的 App）。代价就是：当弱激活没能把浏览器带到前台时，**没有任何补救、也没有任何记录**。

**修法（三层）**：
1. **激活可观测 + 一次性升级**：新增 `bringBrowserForward(appName)` —— 记录激活前后的 frontmost bundleId；若弱激活后浏览器仍不是前台，**升级一次** `.activateAllWindows` 并在 0.75s 内轮询确认，日志形如
   `[activate] Safari not frontmost after weak activate (returned=true frontmost=com.apple.finder before=com.apple.finder); escalating to activateAllWindows`
   `[activate] Safari frontmost=com.apple.Safari visible=true escalated=true before=com.apple.finder`
2. **托管窗口取消最小化**：AppleScript 找到目标窗口后先 `if miniaturized of hostWindow then set miniaturized of hostWindow to false`（Chromium 方言用 `try … end try` 包住），再切标签、置顶窗口 —— 最小化的窗口“跳成功了也看不见”。
3. **不可见就不吞卡片**：`BrowserJumper.jump` 现在返回“用户能不能看见”（`JumpPolicy.isVisibleToUser(navigated:browserIsFrontmost:)`）；`performAction` 与点击回调把它传回主线程，**只有确认可见才 dismiss 卡片/删掉那一行**，否则保留（日志 `[cards] jump not visible; row N kept so it can be retried`）。卡片不再因为一次看不见的跳转而消失。

**取舍与验证**：弱激活（不打扰其它 Space）仍是首选，只有确认失败才升级；`JumpPolicy.activationSettleSeconds = 0.75s` 给激活留出轮询窗口但不会卡住 UI。socket `debug` 命令的回复现在带 `{"ok":true,"outcome":"visible|unconfirmed|notApplicable","visible":true|false}`，可以在不打卡片的情况下直接验证这条链路（前台 App 状态由 `frontmost→escalated→visible` 三段日志给出）。

### 20.1 一轮评审后的修正：三态语义 + 按身份删行

第一版把「用户能不能看见」直接做成 `Bool`，被 AI 审查判为 **[4] 严重**：**若干路径无条件返回 true** —— `sessionId` 缺失的早退只调了 `NSWorkspace.open` 就返回 true；`open-folder` / `open-web` / `default` 分支同样恒 true。这些路径**从未做过前台校验**，却向调用方报告“可见”，于是卡片照旧被 dismiss —— 与本次要修的「假成功」是同一类问题。

**改法（三态，纯策略在 Core 可测）**：

| 结果 | 含义 | 卡片/行 |
| --- | --- | --- |
| `visible` | 动作执行了，且确认用户看得见（浏览器已在前台/被抬到前台） | 丢弃 |
| `unconfirmed` | 试过了但**确认不了**可见性 | **保留**（可重试） |
| `notApplicable` | 与“位置跳转”无关（无 sessionId 只打开 GUI 根地址、纯本地动作） | 丢弃（与旧行为一致） |

`JumpPolicy.shouldDismissCard(after:)` 就是这条规则（只有 `unconfirmed` 保留），`open-folder` / `open-web` 也改成**先确认前台**（Finder / 任一浏览器）再返回，不再假装成功。

**第 2 轮评审又指出一处 [4]（同样是我这次引入的）**：`open-folder` / `open-web` 的前台确认轮询跑在**主线程**上 —— `jump()` 对非 `jump-web` 动作走的是 `completion?(run())` 同步分支，而这个分支由点击的 mouseUp（主线程）调用，`confirmFrontmost` 内部是 0.75s 的 `Thread.sleep` 忙等，于是点这类卡片会让 UI 卡最多 0.75s，也违背了本文件“驱动浏览器一律下后台”的既有约定。改法：**凡是需要回报结果的动作统一进后台队列**，完成后再跳回主线程回调（`guard completion != nil || action == "jump-web" else { fire-and-forget }`）—— 不再有“只有 jump-web 才下后台”的特例。同一轮还把 `debug` 命令的注释改准：它只覆盖 `jump-web` 语义，`open-folder`/`open-web` 的真实点击会额外做前台确认，可能得出 `unconfirmed`，不要把它当成“完全镜像”。

**另一处（[2] 轻微，但窗口是我这次引入的）**：把行删除改成异步回调后，回调里的 `row` 行号可能已经陈旧 —— 两次快速点击不同行、回调乱序返回时，会删掉**相邻**那一行。改成**按身份删除**：点击时抓下该行的 `CompletionEntry`，回调里用 `CardModel.index(of:)` / `removeCompletion(matching:)` 按 `message+kind+time` 重新定位，找不到就当作“已被另一次点击处理”跳过。XCTest 与 `test/core-local-check.sh` 都覆盖了「先前删掉一行后按身份删仍删对行」。
