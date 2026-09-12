# L2 设计：SwiftPM 拆分 daemon + CardModel 状态机 XCTest

> 状态：设计稿（待评审）。目标分支从 `main`（含 L1 vitest 基线，PR #1/#2 已合并）出发。
> 原则：**先行为锁定，再结构拆分；拆分 PR 不含行为改动；测试在拆分完成后补上**。

## 1. 动机（为什么现在做）

`bin/dsh-notify-server.swift` 单文件 1224 行 + **顶层 main**（`NSApplication` 引导在文件尾）导致：

- 无法被 XCTest `import`（顶层代码不可作库目标）→ daemon 核心状态机**零自动化测试**；
- 历轮 AI review 抓到的 UI 状态机类 bug 全部落在这里：聚合行折叠边界、dismiss/relayout 动画冲突、`removeCompletion` 重排、并发竞争 —— 这些本可在提交前被单测拦住；
- 聚合/优先级/文案逻辑（`NotificationCard` 内）与实际 AppKit 渲染强耦合，改一处动全局。

L1（Node 纯逻辑）已证明"提取纯函数 + 回归测试"能显著降低 review 噪音（78→95 分）。L2 把同一套做法用于 daemon 里**最有价值但最不可测**的部分。

## 2. 现状盘点（按可测性分层）

| 现有符号（行号基于 760b676 后） | 性质 | 归属 |
|---|---|---|
| `dshLog` / `fillSockaddr` / `daemonAlreadyRunning` | 副作用（文件/进程） | 壳 |
| `ShowRequest` + socket JSON 解析 | **纯**（Decodable + 默认值） | 可测 → Core |
| `OutcomeKind`（parse / color） | parse 纯；`color` 依赖 NSColor | Core 留纯枚举，颜色移 UI 扩展 |
| `CompletionEntry` / `NotificationCard` 内聚合逻辑（addCompletion / removeCompletion / contains / dominantKind / summaryLine / auto-collapse / 展开状态） | **纯状态机**（不碰 window） | 抽出 `CardModel` → Core |
| `NotificationCard` 本体（NSWindow 创建、updateFrame、动画、autoDismiss 定时） | AppKit | 壳（持有 CardModel） |
| `CardView`（绘制、命中测试、mouseUp 语义、whale path） | AppKit | 壳（读 CardModel） |
| `CardStack`（show 合并、relayout） | AppKit（窗口布局） | 壳 |
| `BrowserJumper` | 副作用为主（osascript / NSWorkspace） | 壳；**纯策略**（候选排序、重试判定）抽 Core |
| 顶层 main / `NSApplication` | 引导 | 壳 |

## 3. 目标结构（SwiftPM）

```
Package.swift                     # swift-tools-version 5.9+；platforms: macOS 13+
Sources/
  dshNotifyCore/                  # library（仅 Foundation，无 AppKit）
    OutcomeKind.swift             # 纯枚举：completed/error/blocked + parse(退化 completed)
    CompletionEntry.swift
    CardModel.swift               # 从 NotificationCard 抽出的纯状态机（见 §4）
    ShowRequest.swift             # Decodable + 默认值（message/sessionTitle/kind 兜底）
    JumpPolicy.swift              # 纯函数：candidateOrder(lastHostingBrowser:)、
                                  #        shouldRetry(hadDenied:pass:maxPasses:)
  dshNotifyServer/                # executable（AppKit 壳）
    main.swift                    # NSApplication 引导 + socket path 参数
    Diagnostics.swift             # dshLog
    NotificationCard.swift        # 窗口壳，内部持有 CardModel
    CardView.swift                # 绘制/命中/鼠标（读 CardModel 数据）
    CardStack.swift
    BrowserJumper.swift           # AppleScript/NSWorkspace 副作用，调用 JumpPolicy
    OutcomeKind+Color.swift       # color / dimColor（NSColor 扩展，Core 不 import AppKit）
    SocketServer.swift
Tests/
  dshNotifyCoreTests/             # XCTest（swift test）
```

关键点：

- **拆分边界** = 「不碰 `NSWindow/NSView/NSColor` 的代码进 Core」。`NotificationCard` 变成薄壳：持有 `CardModel`，`entries/completionCount/dominantKind/summaryLine` 全部转发给 model，自身只做窗口/动画/定时。
- **产品/二进制名不变**：`bin/dsh-notify-server` 路径与插件 `serverPath` 默认值不变。构建产物 `swift build -c release` 后拷贝到 `bin/`（与现在 `swiftc` 输出同路径），部署流程不变。
- **可同时保留 `swiftc` 单文件编译**作为快速路径？不 —— 双构建源会漂移。以 Package.swift 为准，README/build 说明同步改（见 §7 风险）。

## 4. CardModel 抽出的状态机语义（必须原样保留）

从 `NotificationCard`（行 ~133-340）搬到 Core 的行为：

1. `entries: [CompletionEntry]`（到达序，最后=最新，index 1 基）；
2. `addCompletion(message:kind:detail:at:)` → 追加、index = count+1；
3. `removeCompletion(index:)` → 移除后**重排 index**、`entries.count <= 1` 时 `expanded = false`（auto-collapse）；
4. `completionCount` / `newestEntry` / `isCollapsed`；
5. `contains(kind:)`；
6. `dominantKind`：blocked > error > completed（存在性优先级，非最新优先）；
7. `summaryLine`：单条=message(+detail)；全部 completed=`已完成 N 次 · 最近 hh:mm`；有 error=`N 次中 M 次失败 · 最近 hh:mm`；有 blocked=`N 次中 B 次需你处理 · 最近 hh:mm`（blocked 文案优先于 error）；
8. `expanded` 置位/翻转由 UI 触发，但 auto-collapse 规则在 model 内。

> 备注：`CardView.rowIndex(at:)` 的行号换算（`(y - headerHeight)/rowHeight+1`）是纯算术但依赖 UI 常量，先留在 UI；如需测，把公式挪成 CardModel 的静态函数并注入常量。

## 5. XCTest 计划（拆分完成后第一批红→绿）

`Tests/dshNotifyCoreTests/`：

- **CardModel 聚合**：addCompletion 索引连续性；同 session 多 completion 顺序；
- **removeCompletion**：删中间条目后 index 重排无空洞（review 复现点）；3→2 保持 expanded；2→1 auto-collapse；删到 0 的边界；
- **dominantKind 优先级**：blocked>error>completed（含混合三种）；
- **summaryLine**：单条带/不带 detail；全 completed 计数；含 error 计数文案；blocked 覆盖 error；
- **ShowRequest 解码**：kind 缺省→completed；非法 kind→completed；message/sessionTitle/action 缺省兜底；
- **JumpPolicy**：lastHostingBrowser 优先排序；连续 denied 是否重试（hadDenied/pass 边界）；全 noHost 不重试。

## 6. 行为锁定：拆分前先建验收脚本（防漂移）

拆分会动 1224 行文件与构建路径，**先锁行为再动手**：

1. 新建 `test/socket-smoke.sh`（或 `scripts/`）：起 daemon → `ping` → 推多场景 `show`（单 completed / 同 session 多次合并 / error / blocked / 两个 session 堆叠）→ 断言进程存活、socket 可往返、日志关键行存在；视觉项打印检查清单由人确认；
2. 在**当前 main** 上跑一遍存底；
3. 拆分提交（PR-A）后重跑同一脚本 → 行为不一致即中止；
4. 再补 XCTest（PR-B）把状态机语义固化。

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 构建路径变更（`swiftc` 一行 → `swift build`） | 产物仍拷到 `bin/dsh-notify-server`；README「构建」节与 docs 同步；profile 部署脚本验证一次 |
| 大文件搬迁引入行为漂移 | 验收脚本先行；每步一个提交；PR-A 纯结构（零行为注释可 review） |
| AppKit 与 Core 误耦合（如 NSColor 漏进 Core） | Core 编译期守卫：不 import AppKit；颜色放 UI 扩展 |
| `NotificationCard` 壳层改动影响渲染 | 壳层只转发，绘制逻辑（CardView）不动 |
| SwiftPM 首次引入的本地工具链差异（module cache/沙箱） | 文档记录 `swift build -c release --disable-sandbox` 或 module-cache 参数（沿用本仓库踩坑 §？） |
| PR 过大触发 review 噪音 | 拆两个 PR：A=结构拆分（验收脚本绿），B=补 XCTest；各自独立过 AI review 与合并 |

## 8. 验收标准

- `swift test` 全绿（首批状态机用例）；
- `swift build -c release` + 拷贝产物后，`test/socket-smoke.sh` 与拆分前结果一致；
- daemon 点击行为人工回归一次（completed 跳转 / blocked 只聚焦 / 聚合展开收合 / 拖右清除）；
- 插件路径、socket 路径、`bin/dsh-notify-server` 默认值不变；profile 部署无感。

## 9. 范围外（本阶段不做）

- CardView 绘制/命中/动画的自动化（AppKit，人工回归 + socket 冒烟覆盖）；
- L3 Playwright client harness（浏览器侧，另行立项）；
- daemon 与 host 的事件契约取证（error→completed 双通知等，等真实异常再推动）。

## 10. 里程碑

1. `test/socket-smoke.sh` 在 main 存底（可并入 PR-A）；
2. **PR-A**：建 Package.swift + 双 target，行为零改动搬迁，验收脚本绿；
3. **PR-B**：CardModel/ShowRequest/JumpPolicy 的 XCTest 首绿；
4. 文档同步（README 构建节、docs 踩坑新增 SwiftPM 条目）。

## 11. 本地 Core 自检（`test/core-local-check.sh`）

本机只有 Command Line Tools，**`swift test` 跑不起来**（`xcrun: unable to lookup item 'PlatformPath'`），XCTest 只在 CI 的 macos-15 runner 上执行 —— 于是 Core 的错要等 CI 才知道。代价实测过一次：快照兼容性用例手写了一段 JSON 夹具，`"time": 1` 看着没问题，但 `CardStackStore` 的 decoder 是 **`.iso8601`**，解码直接抛错 → `.corrupt` → 本地全绿、CI 红。

`test/core-local-check.sh` 用 `swiftc` 把 `Sources/dshNotifyCore/*.swift` 和 `test/core-local-check.swift` 编成一个可执行文件（swiftc 只允许 `main.swift` 里写顶层代码，脚本里先拷成 `main.swift`），直接跑不依赖 XCTest 的关键不变量：

- 逐行锚点：每行各自的 `turn`、`removeCompletion` 重排后不丢、行号越界/表头回落 `cardTurn`、都没有则 `nil`；
- 快照往返：卡片级 + 逐行 `turn`；
- **旧格式兼容**：把真实快照编码后**摘掉条目的 `turn` 键**再读回（而不是手写文件 —— 手写会与 ISO8601 日期格式漂移），必须 `loaded`；
- 深链：`&turn=` 只在正数时出现。

它断言更少，**不是 XCTest 的替代品**：CI 的 `Tests` 工作流两个都跑（`swift test` + 本地自检脚本），权威基线仍是 XCTest。

## 12. 本地 XCTest **类型检查**（`test/typecheck-swift-tests.sh`）

`parse-swift-tests.sh` 只是 `swiftc -parse`：**语法**过得去，类型错误照样漏。实测踩雷：给 `SnapshotTurnTests` 写新用例时引用了 `t0` —— 那是**另一个类** `CardStackSnapshotTests` 的私有属性，于是 CI 的 macos runner 直接编译失败（`cannot find 't0' in scope`），测试一条都没跑，白等一轮 CI；本机 `-parse` 全绿，毫无提示。

做法：本机确实没有 XCTest，但**可以造一个只含 API 声明的同名模块**：

1. `swiftc -emit-module -enable-testing -module-name dshNotifyCore` 把 Core 编成模块（`-enable-testing` 才能 `@testable import`）；
2. `test/xctest-shim/XCTest.swift` 声明测试用到的 API 子集（`XCTestCase`、`XCTAssertEqual`/`True`/`False`/`Nil`/`NotNil`、`XCTFail`、`XCTUnwrap`，含 `accuracy:` 重载）编成 `XCTest.swiftmodule`；
3. `swiftc -typecheck -I <临时目录> Tests/dshNotifyCoreTests/*.swift` —— 只做类型检查，不链接、不执行。

**桩模块必须 `@_exported import Foundation`**：真实 XCTest 会再导出 Foundation，测试源码只写 `import XCTest` 就能用 `Date`/`DateFormatter`；不写这行会误报 `cannot find type 'Date' in scope`。

它是**类型检查**，不替代 CI：断言实现是空的（`XCTUnwrap` 只保证返回类型），跑不出结果，权威基线仍是 `swift test`。两个本地脚本的分工：

| 脚本 | 查什么 | 需要 XCTest |
| --- | --- | --- |
| `test/parse-swift-tests.sh` | 语法（括号/结构） | 否 |
| `test/typecheck-swift-tests.sh` | 类型（作用域/API 签名） | 否（用桩模块） |
| `test/core-local-check.sh` | 关键不变量**真跑一遍** | 否（`swiftc` 直编可执行） |
| `swift test`（CI） | 全量断言 | 是 |
