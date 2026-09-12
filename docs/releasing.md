# 发版流程

> 本仓库**没有 npm 包**（npm 注册页对代理/机房 IP 有 Cloudflare 拦截，放弃）。版本号只用于
> **tag / CHANGELOG / package.json 三者对齐**。

## 每次发版

1. **升版本**：改 `package.json` 与 `package-lock.json` 的 `version`，`CHANGELOG.md` 顶部写同一版本号；
2. **走 PR 合进 main**：CI 会跑 vitest / XCTest / 冒烟 / Playwright + AI 评审；
3. **需要预编译二进制时**（只有改了 Swift 代码才需要）：`scripts/build-universal.sh`，产物落到 `bin/`；
4. **建 Release**：GitHub UI 里用 tag 形如 `v0.1.1`，正文按 `CHANGELOG.md` 那一段写。
   Release 的自动源码包**自带 `bin/` 里的 universal 二进制**，朋友下载即可用，不必编译。

版本号约定：0.x 阶段功能/修复直接升 patch（`0.1.0 → 0.1.1`），有明显行为变化再升 minor（`0.2.0`）。

## 发布后自检（建议每次都做一遍「干净装机」）

```bash
# 1) 卸载现有安装，拿到"朋友视角"
dsh plugin --profile web remove dsh-notify-macos

# 2) 按对外文档里的方式安装（github: 或 Release 的 .tgz）
dsh plugin --profile web add github:Tania-X/dsh-notify-macos

# 3) 确认插件进了 profile 层栈 —— 这一步不需要手工编辑任何 patch 文件
dsh --profile web --dump-config | grep -A 3 notify-macos

# 4) 重启 dsh 后完成一个小任务，看卡片是否弹出、点击是否跳转
dsh web
```

第 3 步是这套打包方式的关键验收点：插件用自己的 `cordis.patch.yml` 声明 `dsh.bundle`，
`dsh plugin` 会把它并入 `dsh.profile.bundles`，**用户不需要手工插入条目**。

## 对外说明里可用的安装方式

| 方式 | 命令 | 代价 |
| --- | --- | --- |
| **GitHub 依赖（推荐）** | `dsh plugin --profile web add github:Tania-X/dsh-notify-macos` | 首次约 3 分钟（git） |
| Release 附件 | 下载 `dsh-notify-macos-<版本>.tgz` 后 `add <路径>` | 秒级；但 profile 里记的是**绝对路径**，把 tgz 挪走后任何 `pnpm install` 都会 `ENOENT`（插件本身仍可用） |
| npm | — | **暂不做** |

## 配置覆盖（不必改包里的默认值）

包内的 `cordis.patch.yml` 只提供默认配置；用户要改就在 **profile 自己的** `cordis.patch.yml`
里按 id 覆盖（用户层永远在 bundle 层之后应用）：

```yaml
# $DSH_HOME/profiles/web/cordis.patch.yml
- id: notify-macos
  config:
    socketPath: /tmp/dsh-notify-macos.sock
```
