# dsh-notify-macos

DeepSeek Harness（DSH）的 macOS 通知插件：任务一结束，就在屏幕右上角弹出**常驻悬浮卡片**；
点一下，浏览器**原地跳到那个会话的完成位置**。切去干别的也不怕错过 —— 卡片会一直等你。

```
┌──────────────────────────────────────────┐
│  ● 我的数据分析会话                  ▾   │  ← 标题 = 会话名
│    已完成 2 次 · 最近 14:32              │  ← 同一会话多次完成会合并
├──────────────────────────────────────────┤
│  14:31  任务已完成                        │  ← 展开后逐行点：跳各自的位置
│  14:32  任务失败，点击查看详情            │
└──────────────────────────────────────────┘
```

## 三种状态，一眼分辨

| 卡片 | 什么时候出现 | 点击它 |
| --- | --- | --- |
| 🟢 **completed** | 任务正常结束 | 跳到这次完成的**位置**（不是会话底部） |
| 🔴 **error** | 任务异常结束（报错/中断/超 token） | 同上，去看发生了什么 |
| 🟠 **blocked** | 需要你处理：等你授权、或等你回答问题 | 跳到等你处理的现场 |

## 安装

前置：macOS（插件只支持 macOS）+ 已经在用 DSH 的 web profile（`dsh web`）。

```bash
# 一条命令：装进 web profile 并自动激活（包内声明了 dsh.bundle）
dsh plugin --profile web add github:Tania-X/dsh-notify-macos

# 然后重启 dsh，让它完成一个小任务试试
dsh web
```

**不需要手工编辑任何 patch 文件**：包内自带 `cordis.patch.yml`，`dsh plugin add` 会把它并进
profile 的层栈。装完可以这样确认：

```bash
dsh --profile web --dump-config | grep -A 3 notify-macos   # 应看到 notify-macos 条目
```

> **想改配置**（换 socket 路径、关掉提示音等）不用动包里的文件，在 **profile 自己的**
> `cordis.patch.yml` 里按 id 覆盖即可（用户层永远在 bundle 层之后应用）：
> ```yaml
> # $DSH_HOME/profiles/web/cordis.patch.yml
> - id: notify-macos
>   config:
>     socketPath: /tmp/dsh-notify-macos.sock
> ```
> 可覆盖的字段见下面的「配置」。

**装好了怎么确认**

```bash
# 插件被 GUI 加载了吗（应看到 notify-macos，且是 active）
curl -s -X POST http://127.0.0.1:3080/api/pluginInventory/list \
  -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v1","method":"pluginInventory/list","payload":{"args":{}}}'

# 守护进程活着吗（注意：请求必须以换行结尾）
printf '{"cmd":"ping"}\n' | nc -U "$TMPDIR/dsh-notify-macos.sock"   # → {"ok":true}
# 若你在配置里钉了 socketPath，就换成那个路径（例如 /tmp/dsh-notify-macos.sock）
```

> **二进制说明**：仓库里预编译的 `bin/dsh-notify-server` 是 **universal（Apple Silicon + Intel）**，
> 两种 Mac 都能直接用。若它被 Gatekeeper 拦下（从浏览器下载的压缩包会带隔离标记）：
> `xattr -dr com.apple.quarantine /path/to/dsh-notify-macos`。
>
> 想自己重新编译（改代码后，或换平台版本）：
> ```bash
> swift build -c release && cp .build/release/dsh-notify-server bin/   # 只编本机架构
> scripts/build-universal.sh                                          # 编 universal 双架构
> ```

## 使用

装着就不用管了。任务结束时卡片自己出现，然后：

| 操作 | 效果 |
| --- | --- |
| **点某一行** | 浏览器跳到那一行**自己的完成位置**，并移除该行（一行一行处理） |
| **点卡片标题** | 展开/收起多行明细（单行卡片点了就是跳转） |
| **往右拖拽** | 清掉这张卡（整个会话的通知一起清） |
| 什么都不做 | 卡片常驻，直到你处理；**重启 dsh / daemon 崩了也不会丢**（有快照恢复） |
| 🟠 琥珀行 | 你在 GUI 里点了同意/拒绝、或回答了提问之后，**它自己消失**（不用手动清） |

跳转是**原地切换**：浏览器不刷新、不新开标签页，直接落到该会话的那次完成处；如果那次完成已经滚出可视区，它会自动点「加载更早」翻回去。

**首次点击会弹一次系统授权**：macOS 会问「**终端**（或你启动 dsh 的那个 App）想要控制 Safari / 浏览器」→ 允许即可。
这是 macOS 自动化权限，只需一次；它归属于**启动 dsh 的那个 App**，不是本插件。

## 配置

都写在 `cordis.patch.yml` 的 `notify-macos.config` 里：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `clickAction` | `"jump-web"` | 点击行为：`jump-web` 跳会话 / `open-web` 打开 `webUrl` / `open-folder` 打开工作目录 / `none` 只消除 |
| `webUrl` | `"http://127.0.0.1:3080"` | GUI 地址（端口不同就改这里） |
| `messageCompleted` | `"任务已完成"` | 🟢 卡片正文 |
| `messageError` | `"任务失败，点击查看详情"` | 🔴 卡片正文 |
| `messageBlocked` | `"需要你处理，点击查看详情"` | 🟠 卡片正文 |
| `sound` | `false` | 弹卡片时是否播提示音 |
| `rootOnly` | `true` | 只通知顶层会话；`false` 时子代理完成也通知 |
| `autoDismissSec` | `0` | 自动消失秒数（`0` = 常驻） |
| `title` | `"DeepSeek Harness"` | 拿不到会话名时的兜底标题 |
| `socketPath` | `$TMPDIR/dsh-notify-macos.sock` | 与守护进程通信的 socket（示例配置里钉成 `/tmp/...` 只是为了好敲） |
| `serverPath` | 包内 `bin/dsh-notify-server` | 守护进程路径 |

## 出问题先看这几条

| 症状 | 先检查 |
| --- | --- |
| 完全不弹卡 | `dsh web` 是否在跑；`cordis.patch.yml` 里是否注册了 `notify-macos`；改完 host 半区要**重启 `dsh web`**（不是热更新） |
| 点卡片没反应 | 首次点击的 macOS 自动化授权是否点了「允许」；终端里 `log` 见 `docs/troubleshooting.md` §20 |
| 抬起来的浏览器窗口不对 | 宿主窗口在别的桌面/被最小化时的分支行为，见 §20 / §22（§22 的探测机制已按 §23 简化） |
| 琥珀卡片不自动消失 | 该行对应的授权/提问是否真在 GUI 里处理过（§24） |
| 卡片莫名消失 / daemon 不见了 | daemon 会自愈重启；历史上"凭空消失"的根因是 SIGPIPE，见 §21 |
| 想自己查状态 | 见 [docs/protocol.md](docs/protocol.md)：`ping` / `state` / `probe` / `debug` |

完整踩坑记录（每一条都有真实现场与修法）：[docs/troubleshooting.md](docs/troubleshooting.md)。

**要给作者反馈问题时，附上这三样最有用**：

```bash
printf '{"cmd":"state"}\n' | nc -U "$TMPDIR/dsh-notify-macos.sock"  # 当前卡片状态
tail -50 /tmp/dsh-notify-macos.log                                 # 守护进程日志（固定路径）
sw_vers; uname -m; dsh --version                                # macOS / 架构 / DSH 版本
```

## 它是怎么跑起来的（简略）

```
DSH host 进程（lib/index.js）
  │  监听 turn/end、approval/asked、tool/call，归一成 completed / error / blocked
  │  Unix socket 推一条 show 指令（带 sessionId、turn 位置锚点、blocked 行的关联键）
  ▼
dsh-notify-server（Swift/AppKit 守护进程，插件按需拉起）
  │  在右上角画卡片；点击时用 AppleScript 把 GUI 标签页指向
  │  http://127.0.0.1:3080/#dsh-notify-macos/session=<id>&turn=N
  ▼
client 半区（lib/client.js，跑在 GUI 页面里）
     收到 hash → 调前端原生 sessions.open(id) → 滚到那个 turn 的完成处
```

三个刻意的设计取舍，值得知道的只有这些：

- **跳转不碰 DOM**：守护进程只负责把标签页指向一个 hash，页面里的 client 半区用前端原生 API 切会话（无需浏览器「允许 AppleScript 执行 JS」那种授权）；
- **卡片持久化**：卡栈原子写进 `<socketPath>.cards.json`，daemon 重启/崩溃后未处理的卡片自动回来；
- **不猜"你看见没有"**：只判定"跳转有没有交给浏览器"，交出去了才消除卡片，否则保留可重试（细节与教训见 §20/§23）。

更多设计文档：[docs/l2-swiftpm-split.md](docs/l2-swiftpm-split.md)（Core/服务端分层）、[docs/roadmap.md](docs/roadmap.md)（后续拓展与同类项目对比）。

## 开发与测试

```bash
swift build -c release            # 编译守护进程
cp .build/release/dsh-notify-server bin/   # 产物就位（serverPath 默认指向这里）

npm test                          # host/client 纯逻辑（vitest，48 条）
./test/socket-smoke.sh            # daemon 协议冒烟（24 条，含竞态与 SIGPIPE 断言）
./test/core-local-check.sh        # Core 不变量自检（swiftc 直编，无需 XCTest）
./test/typecheck-swift-tests.sh   # XCTest 源码类型检查（桩模块，无需 XCTest）
swift test                        # 完整 XCTest（需含 XCTest 的 Xcode 工具链）
npm run test:e2e                  # client 半区 Playwright（自带 harness 页）
```

CI（`.github/workflows/tests.yml`）：ubuntu 跑 vitest + Playwright，macos-15 跑 `swift test` + Core 自检 + 真 socket 集成测试。

## 平台与许可

- 仅 macOS。守护进程用 Swift 5.9+ / SwiftPM 编译；仓库内附 **universal（Apple Silicon + Intel）** 预编译二进制（构建方式见 `scripts/build-universal.sh`）。
- MIT，见 [LICENSE](LICENSE)。改动记录见 [CHANGELOG.md](CHANGELOG.md)。
