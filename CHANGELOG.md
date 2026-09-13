# 变更记录

## 0.1.2 — 2026-09-13

**升级安全**：DSH 升级可能改动插件依赖的契约，这一版把「插件加载失败」从"可能拖垮 harness"变成"安静降级"，
并给出一套升级前后可跑的自检。

- **防御式加载（host + client 半区）**：`apply()` 外层 try/catch、`ctx.on` 能力探测、每个事件 handler 各自兜底、
  异步派发（`deliver` / `clearKeyedRow`）不再产生 unhandled rejection、日志本身失败也不会抛 ——
  契约变化时的表现是"卡片不弹"，而**不是** DSH 启动失败；
- **契约自检** `test/manual/contract-check.mjs`：只读本机安装，5 秒核对事件词表（事件名从
  `lib/index.js` 抽出 —— 同时覆盖 `event.type === "…"` 与 `switch (event.type) { case "…" }`
  两种写法，并带"抽到 0 个就判失败"的自保，避免正则失配后检查静默变成永远通过）、`agent/status`、
  `ask_user_question`、前端锚点（`turn-tail` / `loadOlder`）、`sessions` 服务与 profile 接线；
  退出码 1 = 核心契约缺失；用假树验证过它**确实能报出**契约变更（词表缺项 → ❌，锚点缺失 → ⚠️ 降级）；
- **README 增「兼容性与 DSH 升级」**：声明针对版本、降级地图（哪种契约变了 → 什么症状）、
  以及升级流程摘要（停写 → 备份 → 隔离 home 试跑 → 门禁 → 提升或回滚）；
- **预编译二进制不再会「和源码对不上」（issue #31）**：`bin/dsh-notify-server` 里嵌**源码指纹**
  （`Sources/**` + `Package.swift` 的摘要），构建时同步写进生成的 Swift 常量与随包发布的
  `bin/dsh-notify-server.fingerprint`；新增只读诊断 `{"cmd":"build"}`（与 `peer` 同形状）、
  CI 门禁 `scripts/fingerprint-check.sh`（纯文本比对，不需要 Swift 工具链）、以及构建脚本末尾
  「启动刚产出的二进制问一句指纹」的自检 —— 专挡 SwiftPM 缓存陈旧那种"只重建了一半"的坑
  （真实踩过）。`contract-check.mjs` 新增第 7 节：核对**正在运行的守护进程**是不是你安装的产物，
  能发现"升级后旧守护进程还在跑、你以为修复生效了其实没有"（CI 永远看不到这个）。
- **信任边界收紧（issue #32）**：守护进程改为**只服务同一个用户** ——
  socket 权限显式 `chmod 0600`（默认受 umask 影响，实测是 `0755`：同机任何用户都能连）、
  `getpeereid()` 取内核给出的对端 uid 并比对（不匹配就**直接关闭、连请求都不读**，只记一行日志，
  协议不变）、快照文件写为 `0600`（里面有会话标题/路径，默认是 `0644`）。
  同一道边界也覆盖了守护进程日志（`/tmp/dsh-notify-macos.log` 原本是 `0644`，而里面真带会话标题、
  session id 与深链 URL）；
  权限是**创建时就带上**的（socket 在 bind 期间收紧 umask、快照自己写 `0600` 临时文件再 rename、
  日志在启动时收紧且新建即 `0600`），
  不是写完再 `chmod` —— 后者存在可读窗口（进程在两步之间被杀会永久停在 `0644`），
  `chmod` 的失败也会记一行日志而不是静默。快照的覆盖用 POSIX `rename(2)`（原子覆盖）：
  `FileManager.moveItem` 在目标存在时会失败，配套的"先删再改名"一旦失败就会**丢掉既有快照**。
  放行 root 是有意的：root 本就能控制本进程，拒绝它只增加故障面。策略是纯函数 + 单测，
  改宽会先让测试变红；新增只读诊断命令 `{"cmd":"peer"}`（让"读到的 uid 是不是真的"可验证，
  见 `docs/protocol.md`）；`test/manual/peer-reject.sh` 用第二个真实 uid 端到端验证拒绝路径；
  顺带修掉守护进程诊断走 `print` 导致被信号杀掉时日志丢失的问题（改走 `dshLog`）。
- **peer 依赖放宽**为 `>=`（去掉上界）：预发布版本的 semver 语义会让"精确范围"变成安装噪音，
  它们只是适配声明，运行时由宿主提供。

## 0.1.1 — 2026-09-12

**安装一步到位**：包内声明 `dsh.bundle`（`cordis.patch.yml`），于是

```bash
dsh plugin --profile web add github:Tania-X/dsh-notify-macos
```

一条命令即完成安装与激活 —— **不再需要手工编辑 profile 的 `cordis.patch.yml`**。
个性化配置改为**按 id 覆盖**（用户层永远在 bundle 层之后应用）：

```yaml
# $DSH_HOME/profiles/web/cordis.patch.yml
- id: notify-macos
  config:
    socketPath: /tmp/dsh-notify-macos.sock
```

同时更新 README（安装简化为一条命令）与 `docs/releasing.md`（不含 npm 的发版流程）。

**实机验证**（本机干净装机）：卸载插件 + 把 profile 的 `cordis.patch.yml` 清空为默认的 `[]`
之后，仅执行 `dsh plugin --profile web add <包>`，`dsh.profile.bundles` 就自动加入了
`dsh-notify-macos`，`dsh --profile web --dump-config` 里出现完整条目 —— **无需任何手工插入**。

顺带记一个坑：profile 的 patch 文件**必须是顶层数组**。把它"注释掉"成只有注释的空文件会解析成
`null`，`dsh` 直接启动失败（`must be a top-level YAML array of loader patch entries`）；
要清空就保留最后一行的 `[]`。

## 0.1.0 — 2026-09-12

**首个公开版本**（给朋友的试用版）。仓库此前未打过 tag、也未对外发布过任何版本，所以号从
0.1.0 起；0.x 表示仍在打磨，欢迎试用与反馈。

### 卡片

- **三种状态**：🟢 completed / 🔴 error / 🟠 blocked（等你授权或回答问题），标题即会话名；
- **同会话聚合**：同一会话多次完成合并成一张卡，展开后逐行看，卡头显示"已完成 N 次 · 最近 hh:mm"；
- **逐行位置锚点**：每一行记住自己那次完成的 turn，点哪行跳哪次的位置（不是会话底部）；
  锚点已翻出可视区时会自动点「加载更早」翻回去；取不到的锚点回退"钉最新"，不会更差；
- **琥珀行自动清理**：你在 GUI 里点了同意/拒绝、或回答了提问之后，对应那一行自己消失
  （行级关联键 `approval:<id>` / `ask:<callId>` + `clear` 协议）；删到只剩一行自动折叠、删空整卡消失；
- **右划清除**整张卡；
- **卡片持久化**：卡栈原子写盘，`dsh` 或守护进程重启/崩溃后未处理的卡片自动恢复。

### 跳转

- 跳转方式为 **URL hash 深链 + client half**：守护进程把 GUI 标签页指向
  `#dsh-notify-macos/session=<id>&turn=N`，页面内的 client 半区用前端原生 `sessions.open(id)` 切会话并
  滚到位置 —— 不刷新、不新开标签页，也不需要浏览器「允许 AppleScript 执行 JS」授权；
- **只判定"命令有没有交给浏览器"**：交出去了才消除卡片，否则**保留卡片可重试**（不再出现"点了卡片
  它直接消失、却什么都没跳"）；抬窗口用 AppleScript `activate`，并优先恢复被最小化的窗口。

### 稳定性

- 守护进程**自愈**：host 半区发送失败会拉起守护进程并重试（`show` 与 `clear` 都如此）；
- **忽略 `SIGPIPE`**：对端中途挂断不再静默杀死守护进程（历史症状：无 crash 报告、日志 0 字节、进程凭空消失）；
- **dismiss 中间态统一处理**：正在消失的卡片在合并/`relayout`/`persist`/`clear`/`state` 五处都被当作"已经不在"，
  修掉"新通知被吞"、"卡片飞出去又被拽回"、"重启后出现 0 行空卡"三类问题。

### 二进制

- 预编译守护进程改为 **universal（arm64 + x86_64）**：Apple Silicon 与 Intel Mac 都能直接用；
  构建方式为「分架构交叉编译 + `lipo` + ad-hoc 签名」（`scripts/build-universal.sh`，只需 CLT 不需要完整 Xcode）。

### 安装与文档

- 安装走 DSH 官方方式：`dsh plugin --profile web add <包>` + `cordis.patch.yml` 注册；
- 新增 `docs/protocol.md`（socket 协议与诊断命令）、`docs/roadmap.md`（拓展点与同类项目对比）、
  本变更记录与 LICENSE；README 重写为"使用优先"。

### 测试

- 48 条 vitest（host 纯逻辑 + 真 socket 集成）+ 24 条守护进程协议冒烟 + 54 条 XCTest
  + 13 条 Playwright（client 半区）；CI 覆盖 ubuntu 与 macos-15。
