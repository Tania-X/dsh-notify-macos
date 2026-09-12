# 变更记录

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
