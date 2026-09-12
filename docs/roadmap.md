# 后续拓展与同类项目对比

这页是**研究笔记**，不是使用说明。当前实现刻意保持"能跑的单体"：下面这些扩展点
**等出现第二个消费者 / 跨平台需求时再逐个落地**，避免提前抽象。

## 同类项目与社区参考

联网调研确认社区已有多个功能相近的 DSH 通知插件，官方（deepseek-ai/deepseek-harness）暂未内置
任务完成通知，但官方「一切皆插件」架构明确留白给社区。

| 项目 | 平台 | 通知形态 | 会话跳转 |
| --- | --- | --- | --- |
| **本插件** | macOS | 右上角自绘悬浮卡片（常驻 / 逐行锚点 / 右划清除） | **URL hash 深链 + client half**（`#dsh-notify-macos/session=<id>&turn=N` → `sessions.open`），守护进程只负责把标签页指向该 hash |
| [dsh-niao-message](https://github.com/dsh-niao/dsh-niao-message) | macOS | 系统通知中心横幅 | 点击直达应用（`open -a`） |
| [TARS-snail/dsh-notify](https://github.com/TARS-snail/dsh-notify) | Linux/桌面 | 桌面通知 | — |
| [dsh-notify-yimit](https://github.com/YiMlT/dsh-notify-yimit) | Windows | 系统通知 + WPF 自绘浮窗 | URL hash 深链 + client half（与本插件同路线） |
| [hotpot-labs/dsh-notifier-plugin](https://github.com/hotpot-labs/dsh-notifier-plugin) | mac/win/linux | 浏览器 `Notification()` / Tauri | — |
| [THEWOLFWALKER/dsh-notifier](https://github.com/THEWOLFWALKER/dsh-notifier) | 跨平台 | IM 推送（telegram/bark/feishu…） | — |

生态汇总清单：[awesome-deepseek-harness](https://github.com/Dominic789654/awesome-deepseek-harness) ·
[awesome-dsh-plugin](https://github.com/Anil-matcha/awesome-dsh-plugin) ·
[dshworks/awesome-dsh-plugins](https://github.com/dshworks/awesome-dsh-plugins)

## 扩展点（按价值排序）

### 1. `BrowserDriver` 协议

现在 Safari 与 Chromium 家族（Chrome/Edge/Brave/Arc/Opera）的差异用 AppleScript 方言分支处理
（`navigateHostingTab` / `focusHostingTab`）。抽成协议后浏览器列表变成驱动注册表：

```swift
protocol BrowserDriver {
    var displayName: String { get }
    func findTab(matching url: String) -> Bool
    func navigate(tab: TabHandle, to url: String) -> Result<Void, Error>
    func activate()
}
```

### 2. `ScriptRunner`（进程/宿主抽象）

现在硬编码 `/usr/bin/osascript`（`Process`）。抽协议后可换 JXA、进程内 `NSAppleScript`，
或 **Firefox 的 DevTools Protocol**（Firefox 没有 AppleScript tab 枚举能力，是当前唯一不支持的浏览器）。

### 3. `CompletionPresenter` 门面（渲染端策略化）

渲染侧只有自绘悬浮卡片一种实现（加插件侧 osascript 兜底）。抽协议后可支持 headless、日志模式、
未来 Linux/Windows 通知：

```swift
protocol CompletionPresenter {
    func present(_ request: ShowRequest)
    func dismiss(id: String)
}
```

### 4. 把 GUI 知识从守护进程剥离

守护进程目前知道 GUI 的 URL 与 hash 形状（`JumpLink`）。更彻底的形态是插件在 `show` 里下发
完整深链模板，守护进程退化为纯执行器 —— 前端改版只改插件，守护进程可通用化服务其他 Harness。

### 5. 协议层现代化

- `show` 载荷里的 `cmd` 字段冗余（handler 里恒为 `"show"`）；
- 手拼 JSON 回复 → `Codable` 枚举 + 类型化回复；
- 增加协议 `version` 字段，支持平滑迁移。

### 6. 更细的生命周期管理

守护进程由插件按需拉起，失败拉起 + 重试已有；可以再加：心跳上报、插件定时 ping 失败自动重启、
退出时清理 socket。

## 已明确「不做」的

决策与原因都记在 `docs/troubleshooting.md`，避免重复讨论：

| 想法 | 结论 | 原因 |
| --- | --- | --- |
| success/fail 卡片「滚到底就自动清空」 | 不做（§25.3） | 要新增 client→host RPC 通道 + 一整套"什么算手动触底/算不算看过"的语义判定，收益只是少一张卡 |
| 让"右划清除"的动效更明显 | 先不做（§25.2） | 纯观感需求不靠文字来回试 —— **先出原型再谈实现** |
| 探测"用户是否真的看见了跳转" | 不做（§23） | 本质不可知，每个启发式都有反例；改为只判定"命令有没有交给浏览器" |
