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
- 进程：`lsof -nP -iTCP:3080 -sTCP:LISTEN` → `node $DSH_HOME/node_modules/.bin/dsh web`（本次 PID 11062）；`ps -o lstart` 显示它**9月10日 01:08** 就启动了，而今天的 PR（#14 turn 跟踪、#15 daemon 自愈）是白天才合进 main 的。
- 行为：此后插件派发的行里没有 `turn` 字段（PR #14 才加的），且 daemon 死了没有触发重拉（PR #15 才加的逻辑）——与“加载的是 9月10日的 host 半区”完全一致。

**结论**：host 半区（`lib/index.js`）是**在 GUI server 进程启动时**加载并被常驻引用的，`cp` 到 profile 目录**不会**让运行中的 GUI 换代码。所以：

- 改 host 半区（事件跟踪 / 下发字段 / daemon 重拉）→ **必须重启 `dsh web`**（在自己终端里 Ctrl-C 后重跑），并刷新浏览器页面让 client 半区重新加载；
- 只改 daemon 二进制（`bin/dsh-notify-server`）→ 重启 daemon 即可，GUI 不用动；
- 只改 client 半区（`lib/client.js`）→ 刷新页面即可。

**附带的一个坑**：daemon 装在终端里用 `... &` 起（没有 `nohup`/`disown`）时，**关掉那个终端会 SIGHUP 把它带走** —— 表现为“没有 crash 报告、日志 0 字节、进程凭空消失”。重启时用：

```bash
nohup $DSH_HOME/profiles/web/node_modules/dsh-notify-macos/bin/dsh-notify-server \
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

本次实测（会话 `<会话 id>`，视口 644px）：

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

> ⚠️ **本节描述的"可见性探测"机制已在 §23 被整层删除**（判定改为「命令有没有交给浏览器」+ AppleScript `activate`）。保留本节作为决策记录。

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

**第 3 轮评审本身「质量未达标」**（judge 62/100 < 阈值 70，工具发了降级说明并提示 rerun；judge 同时指出这轮**没审到** `JumpPolicy` 新增的激活/可见性逻辑 —— 属漏报）。它未过门禁的两条里，有一条是真问题：**载荷缺失时卡片会永远点不掉** —— `open-folder`（`path` 为空）与 `open-web`（`url` 缺失/不可解析）返回 `unconfirmed`，于是卡片被永久保留，只能拖走。这类退化载荷本来就“没有动作可做、也就没有可见性可言”，应返回 `notApplicable`（与旧行为一致：点一下即消除）。另一条是把身份匹配键从 `message+kind+time` 加严到**再加 `detail` 与 `turn`**（避免同 message/kind/time 的两行混淆），两条都只有几行，已一并修掉。

**另一处（[2] 轻微，但窗口是我这次引入的）**：把行删除改成异步回调后，回调里的 `row` 行号可能已经陈旧 —— 两次快速点击不同行、回调乱序返回时，会删掉**相邻**那一行。改成**按身份删除**：点击时抓下该行的 `CompletionEntry`，回调里用 `CardModel.index(of:)` / `removeCompletion(matching:)` 按 `message+kind+time` 重新定位，找不到就当作“已被另一次点击处理”跳过。XCTest 与 `test/core-local-check.sh` 都覆盖了「先前删掉一行后按身份删仍删对行」。

## 21. daemon「凭空消失」的两级真因：请求缺换行 + 缺 SIGPIPE 防护

排查「点击卡片无反应」时顺手撞出来的独立问题，两级原因叠加，表现为**没有 crash 报告、日志 0 字节、进程消失**：

1. **协议：请求以换行结尾才算完整。** daemon 的读取循环是
   `if buffer.contains(0x0A) { break }` —— 客户端不发结尾 `\n`，daemon 就**一直阻塞在 `read()`**，直到对端关闭（EOF）才处理这条请求。表现：调用方看到“超时”，而请求其实**在处理时成功了**（现场：我的人工推送脚本每帧都“超时”，但卡片一张不落全落盘 —— 因为它是在脚本关闭 socket 之后才被处理的）。
2. **缺 SIGPIPE 防护。** 请求在 EOF 之后才被处理，此时对端 fd 已关闭；daemon 写回复 → `SIGPIPE` → **进程被信号杀死**（默认动作），于是没有 crash 报告、日志也是空的。这就是同一天里 daemon 数次“静静消失”的直接原因；插件自己派发（`lib/index.js` 的 `socket.write(\`…\n\`)`）**是带换行的**，所以正常使用不会触发，是**人工探测脚本**（`test/manual/push-anchors.py` 最初版本）把它踩出来的。

**修法**：`Sources/dshNotifyServer/main.swift` 在 main 顶部 `signal(SIGPIPE, SIG_IGN)` —— 作为 socket 服务端，对端提前挂断绝不能杀死守护进程；写失败已被忽略，现在不再致命。探测脚本补上结尾 `\n`（并注明协议要求）。`test/socket-smoke.sh` 新增断言永久锁住这条：**发一条不带换行的请求后立刻挂断，daemon 必须仍然存活**（`PASS: daemon survives a peer that hangs up mid-request (SIGPIPE)`）。

**附带收获**：这两周里 daemon 每次意外死掉都能被插件重新拉起（第 15 号 PR 的自愈逻辑），本次现场也复现了两次（PID 32114 → 32162 → 32244），并且**插件拉起的 daemon 能正常驱动 Safari、没有 `-10004`** —— 说明 Automation 授权沿 GUI server 的责任链继承，人工在终端里起 daemon 已非必需。

## 23. 简化：不再探测「你看见没有」，只保证「命令发出去了」+ 直接把窗口拉到你面前

**用户反馈（原话）**：「我觉得我们好像把问题搞复杂了。」—— 对的，复杂度账本如下：

```
原始需求：卡片点一下 → 跳到那次完成的位置            （小、清楚）
你报的 bug：点了卡片它消失、没跳转                   （真问题）
第一版修复：确认「浏览器到前台了吗」才消除卡片        （引入"验证"这个概念）
你的观察：跳了，但抬起来的是另一个 Safari 窗口        （判据不够）
第二版修复：CGWindowList 在屏窗口 + bounds 匹配 + 容差 + 两级升级  （复杂度爆炸）
```

爆点在于**试图探测「你到底看没看见窗口」**。这件事**本质不可知**：每个启发式都有反例（应用级可见 → 窗口级 → 容差 → `nil` 未知），于是每轮评审都能再找出一个洞。**这不是产品复杂度，是"验证的复杂度"。**

**现在的做法（两态 + 一行 activate）**：

1. **判据退回一个可判定信号**：`performAction` / `BrowserJumper.jump` 返回 `driven` —— 「命令有没有交给浏览器」。**不再声称任何关于"你看见了什么"的判断**（代码注释里写死这条边界，防止再滚回去）。
2. 点击回调：`driven == true` → 消除该行/卡片；`false`（被拒/超时/open 失败）→ **保留该行** + 日志 `[cards] jump not delivered; row N kept so it can be retried`。这就是「不能无声吞掉卡片」的全部实现。
3. **把窗口拉到你面前不用探测，用 `activate`**：AppleScript 在切/聚焦标签、`set index of hostWindow to 1` 之后调用 `activate`（旧语义：macOS 会把这个 App 的窗口带到**用户当前桌面**），并保留 `if miniaturized of hostWindow then set miniaturized of hostWindow to false`（最小化窗口先恢复）。跨桌面场景由此直接解决，零启发式、零容差、零"无法验证的分支"。
4. **代价（如实记录）**：`activate` 可能连带把该浏览器**其它**窗口一起抬起 —— 这正是当初弃用它的原因。当前接受这个代价（「抬得太多」好过「什么都看不到」）；若日后嫌吵，加一个 `bringToFront` 开关即可（一行 config）。
5. **日志里怎么读**：`[jump] navigated tab in Safari (delivered)` = 已交给浏览器；`[cards] jump not delivered; row N kept` = 失败保留；`[jump] automation denied ... NOT opening a new tab` = 授权被拒（此时只把浏览器唤起来，不开新标签页）。socket `debug` 回复同样带 `{"ok":true,"driven":true|false}`。

**被删除的机制**（回溯用）：`WindowBounds` / `boundsMatch` / `isWindowOnScreen` / `shouldEscalateForWindow` / `visibilityVerdict` / `JumpOutcome` / `shouldDismissCard` / `bringBrowserForward` / `CGWindowListCopyWindowInfo` 查询 / 两级升级阶梯 / 激活等待与容差常量 / AppleScript 的 bounds 回报 / Chromium 回退哨兵。净减约 150 行与 2 个不可验证分支。

**保留的（与前几节无关、独立成立）**：逐行锚点（§18.2）、历史翻页 seek（§18.1）、按身份删行（并发点击安全）、结果回报统一下后台队列（不卡主线程）、daemon 自愈、SIGPIPE 防护（§21）、跳转失败不吞卡片。

## 24. 琥珀卡片：你在 GUI 里处理完，卡片自己消失（含自动折叠）

**需求**：琥珀色（blocked）卡片代表「等你处理」。如果你直接在 GUI 上点了同意/拒绝（或回答了 `ask_user_question`），对应的卡片就该自动删掉，不用再去点卡片。成功/失败卡片暂时不动。

**事件取证（真实会话日志）**：

| 产生琥珀行 | 已处理 |
| --- | --- |
| `approval/asked` → `{id, toolName, callId, reason}` | `approval/decided` → `{id, outcome}`（**同一个 id**） |
| `tool/call`（`name=ask_user_question`）→ `{callId}` | `tool/result` → `message.source.callId`（问句被回答时工具才返回） |

两条链路都有**精确关联键**，所以实现不是"按 kind 猜删"，而是给每一行一个 `ref`。

**设计**：

1. **行级关联键**（与 `turn` 同样的下沉方式）：`CompletionEntry.ref` / `SnapshotEntry.ref`，取值 `approval:<id>` 或 `ask:<callId>`；随快照持久化，daemon 重启后仍能清。host 侧 `buildShowPayload` 把它放进 show 帧（`BlockedRefTests` 与 payload 单测覆盖）。
2. **host 判定**：`blockedRef(event)`（产生键）、`resolvedRef(event)`（解决键）、`nextPendingRefs(state, event)`（每会话 pending 集合）、`shouldClearResolved(ref, wasPending, event)`：
   - 我们登记过的 → 发 clear；
   - `approval/decided` 即使没登记过也发（**自愈**：host 重启丢了 pending 时，陈旧的琥珀卡不会赖着不走）；
   - 普通 `tool/result` 只在登记过时发（**每次工具调用都会产生它**，不能无脑发）。
3. **协议**：`{cmd:"clear", sessionId, ref}` → 回复 `{"ok":true,"removed":0|1,"remaining":N,"reason":"no-card"|"no-row"}`。daemon 按 `ref` 删行：**剩 0 行 → 卡片 dismiss**（动画后出栈）；**剩 1 行 → 自动折叠**（`CardModel.removeCompletion` 的既有语义）并重新排布 + 落盘。
4. **绝不误删**：未知 `ref`/未知 session 一律 no-op（不按 kind 猜）；你在 GUI 处理前已经手动点掉该行的话，clear 就是 `removed:0, reason:"no-row"`。
5. **clear 不能静默丢弃**（评审 [4]）：`deliver()` 在发送失败时会拉起 daemon 再重试一次，`clear` 一开始没有同等处理 —— 如果卡片是在 daemon 存活时建好的、之后 daemon 崩了或被重启（卡片从快照恢复），而你正好在这时处理完授权，`clear` 就会因为 daemon 未就绪被扔掉，**琥珀卡永久留在屏幕上**，恰是本功能要消除的场景。现在 `clearBlocked` 复用同一套「失败则拉起 + 重试一次」策略，并且**读取 daemon 的回复**：`removed:0` 记 info（no-op，不是错误）、彻底发不出去则 `logger.warn(... clear dropped (daemon unreachable) ...)`，绝不无声消失。`requestDaemon`（带回复的请求）与 `sendToDaemon`（只等写入的 fire-and-forget）是两个用途不同的助手。

**与既有原则的关系**：这**不冲突**于「跳转失败不吞卡片」—— 那是"你点了卡片但没跳成"，这是"你已经把问题处理掉了"，两者的触发源完全不同。

**测试（自测三层 + 冒烟）**：

- 评审指出的一处真问题已修：`approval/asked` 原来在缺 `id` 时回退用 `callId` 造键，但 `approval/decided` 只带 `id`，这种键**永远匹配不上**、只会留下悬空键 —— 现在缺 `id` 就不给 `ref`（卡片退回"点了才走"的旧行为）；
- vitest **45 条**：纯函数两套（`blocked-resolve.test.js`：键的构造/解析、pending 状态机、payload 必带 ref）+ **真 socket 集成**（`blocked-resolve-integration.test.js`：起一个假 daemon，驱动真实 `apply()`，断言 asked→show(带 ref)、decided→clear(同 ref)、ask→tool/result→clear、**无关 tool/result 不发 clear**、未登记的 decided 仍自愈、别的审批 decided 时不动）；
- XCTest `BlockedRefTests` 5 条（按 ref 只删该行 / 未知 ref no-op / 删到一行自动折叠 / 删空即计数 0 / ref 快照往返）+ 旧格式快照（连 `ref` 都没有）仍能加载；
- `test/core-local-check.sh` 同款断言（本机无需 XCTest 即可跑）；
- `test/socket-smoke.sh` **17 条**：`ref` 落盘、未知 ref/session no-op、删该删的那行、删最后一行卡片消失且栈计数回落、重启后恢复。

**两个坑（都写在测试注释里）**：

1. 集成测试最初用 `os.tmpdir()` 造 unix socket 路径 → macOS 上超过 ~104 字节上限，**connect 静默失败**，看起来像"接线没接对"；改成 `/tmp/...` 短路径。
2. `waitFor(帧数)` 被**预热 ping** 满足（`apply()` 启动就 ping 一次）→ 断言永远看不到 show；改成按**命令**计数（`waitFor("show")`）。

## 25. 卡片生命周期的中间态，以及两个「决定不做」

### 25.1 「卡片还在栈里，但用户已经不需要它」要三处一致对待

dismiss 是**动画**：卡片要等动画结束才从栈里移除，于是存在一个中间态 —— 用户眼里它已经消失了，代码里它还在 `cards`。本次排查中，这个中间态先后在**三处**漏掉，全部修掉（都与动画时长无关，只是动画越长越容易撞上）：

| 漏掉的地方 | 症状 | 修法 |
| --- | --- | --- |
| `CardStack.show` 的合并查找 | 同会话的新完成被并进**正在消失的卡** → 通知画在即将消失的窗口上，用户看不到 | 合并时跳过 `isDismissing` 的卡片，新通知另起新卡 |
| `relayout` | 把正在移出的卡片**拽回右上角栈位** → 看到"移出去又弹回来" | relayout 跳过 `isDismissing` |
| `persist` / `restore` | 把**已经被点空**、正在消失的卡写进快照 → 重启后恢复成一张 0 行空卡（用户现场看到过） | persist 不写 `isDismissing`；restore 跳过 0 行卡片 |
| `clear` 的卡片查找 | 同会话**旧卡正在移出、新卡已建**时，clear 命中那张空掉的旧卡 → 回 `no-row`，**新卡上那行永远删不掉**（琥珀行赖着不走） | clear 也跳过 `isDismissing`（同一根因的第 4 处，由评审抓出） |

「按 sessionId 找卡」这个动作目前有 3 处（合并 / clear / relayout+persist 遍历），**它们必须用同一条规则**；这也是为什么第 4 处漏掉时症状是「琥珀行永远删不掉」而不是崩溃 —— 静默地选错了卡。

`test/socket-smoke.sh` 现在有能真正复现这三条竞态的断言（22 条），其中「新完成必须另起新卡」一条最初写成只数 `cards`，**修复前后在动画窗口内都是 8，属假阳性** —— 改为断言动画结束后的 `cards` + `entries` 组合才有区分度。

### 25.2 决定不做：把右划清除的动效做得"更明显"

曾尝试：位移占满全程（0.34s、easeIn）+ 尾部淡出 + 最小位移兜底 + 终点彻底出屏，让"往右弹出并淡化"更明显。**已撤回。**

原因：**双方对"淡出效果"的预期没对齐** —— 我按"更快更远的甩出 + 尾部淡出"实现，而这并不是用户想要的那种观感。这类**纯观感需求不该靠文字描述来回试**：下次先给**原型**再谈实现（最便宜的三选一：① 先出一段逐帧 storyboard/参数对照，② 做一个只演示该动画的独立小 demo 窗口（不碰插件与 22 条冒烟），③ 用户录一段现有效果并标注想要的差异）。在原型对齐之前，动效保持原样（0.22s、位移到屏幕右缘、同时淡出）。

### 25.3 决定不做：success/fail 卡片「触底自动清空」

曾讨论：把卡片做成「你在 GUI 里手动滚到最新位置（触底）就自动清掉」的成功/失败卡片。**结论：不做。**

- **原因**：需要新增 client→host 的 RPC 通道（`connection.rpc.call` ↔ `ctx.connection.rpc.handle`，类型在 `dsh-client-connection` 的 `rpc.d.ts` 里，但未在运行时验证过），再加上"什么算手动触底 / 什么算看过"的一套语义判定（程序化滚动要排除、进入会话时本来就在底部不算、多会话该清谁……）。收益只是"少一张卡"，复杂度明显不划算 —— 与 §23「不再探测用户看见没有」是同一个教训。
- **现在的契约**：success/fail 卡片**保持原样** —— 点它跳转（并移除该行）、往右拖拽清整张；用户自己看、自己清。琥珀卡片的自动清理（§24）不受影响，仍然只在"你已处理"时触发。

## 26. 点卡片时抬起的是「当前桌面的那个浏览器窗口」，不是 GUI 所在的那个

**用户反馈（实机）**：点卡片后导航确实生效（日志 `[navigate] … tab updated` → `[jump] navigated tab in Safari (delivered)`），但**被抬到前面的却是当前桌面的另一个 Safari 窗口**，GUI 所在的那个仍在后面 —— 手动切过去能看到确实跳好了。

**原因**：脚本里原本的顺序是「`set index of hostWindow to 1` → `activate`」。`set index` 只在 App **内部**给窗口排序，而 macOS 的 `activate` 会把该 App 在**当前 Space** 的那个窗口带到前面，于是刚设的顺序被盖掉。这正是 §20/§23 讨论过的"哪个窗口会被抬起来"在 macOS 上的实际行为。

**修法**：`activate` **之后再置顶一次**（四处脚本：Safari/Chromium × 导航/聚焦）：

```applescript
set index of hostWindow to 1
activate
set index of hostWindow to 1     -- activate 会以「当前 Space 的窗口」优先，这里再盖回来
```

**验证状态**：属**人工验收项**（多窗口/多桌面无法自动测）—— 代码与二进制已就绪，等用户在"GUI 在另一个窗口/桌面"的场景下点一次确认。若仍无效，下一档办法是 Accessibility 的 `kAXRaiseAction`（需要额外授权），或接受此限制并在文档说明规避方式（把 GUI 固定在常用窗口）。

**顺带修掉一个已发布的工具 bug**：`scripts/build-universal.sh` 用 `$TRIPLE` 去拼 SwiftPM 产物目录，而产物目录名不含平台版本（`.build/arm64-apple-macosx/release`），导致 `lipo` 阶段静默失败 —— 也就是说这个脚本从进仓库起就没跑通过。现在改用 `swift build --show-bin-path` 取真实路径。

## 27. socket 谁都能连：同机其他用户能往你桌面推卡片（issue #32）

**怎么发现的**：不是出事之后的复盘，而是把"守护进程暴露了什么"当成一条待查项过了一遍。实测两条：

```
755 /tmp/dsh-notify-macos.sock            # bind 出来的权限受 umask 影响 → 任何本地用户都能 connect
644 /tmp/dsh-notify-macos.sock.cards.json # 快照里有会话标题/路径 → 任何本地用户都能读
```

**为什么这值得修**：守护进程能渲染任意内容的卡片，且点卡片会用 AppleScript 驱动你的浏览器。同机其他普通用户若能连上，就能往你的桌面推卡片（钓鱼/骚扰），并借**你的**权限让浏览器跳转 —— 一个"只服务本用户"的进程没有理由接受别人的连接。

**三道防线**：

| 防线 | 内容 | 位置 |
| --- | --- | --- |
| 文件权限 | **bind 期间收紧 umask（`umask(0o177)`）**，让 socket 一出生就是 `0600`；随后 `chmod 0600` 只作二次确认，**返回值必查**，失败记一行日志（那时只剩 uid 校验在挡，不能静默） | `SocketServer.listenLoop` |
| 对端 uid | `getpeereid()` 取内核给出的对端 uid，与自身 uid 比对，不匹配就**直接关闭、连请求都不读** | `SocketServer.admit` + `dshNotifyCore.PeerPolicy` |
| 快照权限 | 自己用 `0600` 建同目录临时文件再 `rename` —— 权限**一出生就对** | `CardStackStore.save` |
| 日志权限 | 启动时把 `/tmp/dsh-notify-macos.log` 收紧成 `0600`，新建时也直接按 `0600` 建 | `main.tightenLogPermissions` / `dshLog` |

日志也是同一条边界，这点一开始漏了：实测它原本是 `0644`，而里面**真的有会话标题**（`[cards] skipping empty card DeepSeek插件任务完成提醒` 就是一条）、session id 和深链 URL —— 同机其他用户读到 session id 就能对着 `127.0.0.1:3080` 打开你的会话。

**为什么权限要"出生就对"**：第一版写的是「写完再 `chmod`」，AI 评审指出这里有窗口 —— 而它有实锤：改之前实测快照权限就是 `0644`，说明 `Data.write(options: .atomic)`（写临时文件 → rename）产出的文件确实是 umask 默认值，我的 `chmod` 是在那之后才补的；进程若在这两步之间被杀，文件就**永久**停在 `0644`。同一个坑在 socket 上一样成立（默认 `0755`）。现在两处都改成"创建时就带上正确权限"，并各配一条会真红的断言：

- 快照：`attributes: nil` → `core-local-check` 报 `0644/420` FAIL；
- socket：既不收紧 umask 也不 chmod → `socket-smoke` 报 **`socket mode is 755, want 600`** FAIL（顺带重现了原始问题）；
- 日志：把 chmod 换成 `if false` → `socket-smoke` 报 **`daemon log mode is 644, want 600`** FAIL。

**顺带挖出一个语言层面的坑（值得记）**：日志收紧最初写成 `private let tightenLogPermissionsOnce: Void = { chmod(...) }()` 这种"lazy 全局只跑一次"。做咬合验证时它**假通过**了 —— 只删掉调用点，日志权限**仍然**变成 600；把整块声明删掉才停在 644（inode 未变，说明是 chmod 而不是重建）。也就是说**没被引用的声明照样会被初始化**，所谓 lazy 在这个场景里并不成立。它能工作，但那是我说不清、也不该依赖的行为，于是改成在 `main` 里**显式调用一次**。教训是通用的：**"我只删了调用点"不等于"这段代码不再执行"** —— 咬合验证必须看产物/运行时，不能只看源码文本（这次是靠"产物哈希变没变"确认补丁真的进了二进制）。

**为什么放行 root**：root 本来就能读本进程内存、杀掉它、直接读快照 —— 拒绝它不增加任何安全性，只会在有人用 `sudo` 脚本时变成查不出原因的故障面。策略写成纯函数（`PeerPolicy.decide`）并带单测：有人把它改宽成"任何本地用户都放行"，测试会先红。

**为此新增的命令**：`{"cmd":"peer"}` → `{"ok":true,"uid":501}`（内核认定的连接方 uid，只读诊断）。存在的理由是**让安全控制可验证**：拒绝路径需要真实的第二个 uid，CI 里造不出来；但"守护进程读到的是真实对端 uid"可以测 —— 客户端问一句，答案必须等于自己的 uid。顺带也解决了"为什么我的客户端被拒"这类排查。

**验证**（`test/manual/peer-reject.sh`，需要无密码 sudo）：

```
PASS: socket 是 0600（默认 umask 会给出 0755）
PASS: 同 uid 正常：{"ok":true,"uid":501}
PASS: 已放开为 0666，接下来只有 uid 判定在挡
PASS: uid=70 的 ping 没有回复（连接被直接关闭，请求没进解析器）
PASS: 被拒的 show 没有落地（state={"ok":true,"cards":0,"entries":0}）
PASS: 日志里留下了本次的拒绝记录（/tmp/dsh-notify-macos.log）
PASS: 拒绝之后同 uid 仍然正常：{"ok":true,"uid":501}
```

脚本先把 socket `chmod 0666`，让"文件权限"不再是解释 —— 这样剩下的 PASS/FAIL 只可能由 uid 判定决定。

**这一步抓出的两类"假证据"**（都是先做了咬合验证才现形的）：

1. **断言本身无齿**：最初用 `{"cmd":"show"}` 当探针，断言"对端没拿到回复"。但 `show` 是 fire-and-forget，**被接受**时也没有回复 —— 把 uid 判定临时短路后这条断言照样 PASS。改成会回复的 `ping`（短路版立刻红：`竟然拿到了回复：{"ok":true}`）；
2. **日志证据会粘住**：`tail -40 日志 | grep 拒绝` 在短路版也 PASS，因为上一次运行的拒绝记录还在文件里。改成只查**本次新增**的那一段（按运行前的字节数偏移）。

**另一个真实缺陷**：拒绝行最初用 `print` 写，而守护进程的诊断日志走 `dshLog`（固定文件 `/tmp/dsh-notify-macos.log`）。守护进程是被插件 spawn 的，stdout 是块缓冲的，**进程被信号杀掉时缓冲区直接丢** —— 实测"拒绝了陌生 uid"这件事在日志里查无实据。现在 `SocketServer` 的所有诊断都走 `dshLog`。

**协议不变**：只新增一个只读诊断命令 `peer`（见 `docs/protocol.md`）；既有的请求/回复形状一个都没动。

## 28. 提交进仓库的预编译二进制，怎么防止它「和源码对不上」（issue #31）

**为什么会有这个问题**：用户装包即用，不装 Swift 工具链，所以 `bin/dsh-notify-server` 必须提交进仓库。代价是它随时可能**陈旧**：改了 Swift 代码忘了重建、或重建了忘了提交，用户就跑上一个"和源码对不上"的守护进程 —— 这种事真实发生过，当时唯一的线索是 `Build complete! (4s)` 快得不正常（SwiftPM 缓存陈旧）。而 **Swift 构建不可复现**，所以没法用"字节对比"判断，只能对比**指纹**。

**做法**：

| 环节 | 内容 |
| --- | --- |
| 算指纹 | `scripts/source-fingerprint.sh`：`Sources/**/*.swift`（除生成文件）+ `Package.swift`，逐文件一行 `hash  path` 再整体哈希 —— 路径参与摘要，**改名/新增/删除都会变**；`LC_ALL=C sort` 保证跨平台顺序一致 |
| 写进产物 | `scripts/build-universal.sh` 生成 `Sources/dshNotifyCore/GeneratedBuildFingerprint.swift`（`BuildFingerprint.value`，**提交**，这样 `swift test` 在没有脚本的环境也能编）并写一份 `bin/dsh-notify-server.fingerprint`（随包发布，安装副本里只有它） |
| 运行时可见 | `{"cmd":"build"}` → `{"ok":true,"fingerprint":"…"}`（只读诊断，与 `peer` 同一形状） |
| CI 门禁 | `scripts/fingerprint-check.sh`：现算指纹 == 生成文件里的值 == 随包发布的值 == **二进制里真的嵌着它**（前两项是文本比对，第三项 `grep -a` 直接查产物），任一不符即红（**不需要 Swift 工具链**） |
| 构建自检 | 构建脚本末尾会**启动刚产出的二进制**问一句 `build`，比对是不是本次嵌进去的那个 —— 这一步专挡"只重建了一半/缓存陈旧" |
| 运行时比对 | `test/manual/contract-check.mjs` 第 7 节：问运行中的守护进程，与安装副本的 `.fingerprint` 比对 |

最后一项是 CI 永远看不到的：**升级了插件，但旧守护进程还在跑** —— 症状是"我明明修了，怎么没生效"。它报 ❌ 并给出修法（重启 dsh 后旧进程才会退出）。旧版守护进程不认识 `build`（连接被关、没有回复），自检会明确说"大概率是 0.1.2 之前的版本"，而不是含糊地报"没检测到守护进程"。

**为什么门禁要直接查二进制**：只比对两个文本文件，会漏掉"提交了陈旧产物、却把文本指纹更新了"这种组合 —— 那时门禁通过，用户拿到的却是和源码对不上的守护进程。这条是 AI 评审在一个假发现里"想象"出来的场景（它对那次 PR 的判断是错的：产物确实重建了），但**洞是真的**，所以补上了 `grep -a` 查产物这一步。实测有齿：把上一次合并的旧二进制放进来、文本指纹不动 → `FAIL: 提交的二进制里没有当前指纹`。

**它不证明什么**（边界写清楚，免得被当成更强的保证）：指纹证明的是**源码一致**，不是**字节一致**；Swift 版本、工具链差异不在摘要里；有人手工改 `bin/` 里的产物同时伪造 `.fingerprint` 也拦不住（那已经是有意为之，而不是疏忽）。

**咬合验证**（假证据比没证据更坏，所以这两条实测过）：

1. 改一个源码文件而不重建 → `scripts/fingerprint-check.sh` **FAIL** 并指出跑什么命令修；重建后 **PASS**；
2. 用假 `DSH_HOME` + 新守护进程验证运行时比对的 ✅ 与 ❌ 两条路（把安装副本的指纹改成另一串 → ❌ 且给出"重启 dsh"的修法）。
