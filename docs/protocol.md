# 守护进程协议与诊断命令

插件用 **Unix domain socket** 与 `dsh-notify-server` 通信，载荷是 **JSON Lines**（一条请求一行，
**必须以换行结尾** —— 守护进程是以换行判定"请求完整"的；漏掉换行会让它一直阻塞到对端关闭，
你自己看到的是"超时"，而请求其实是在你关闭 socket 之后才被处理的。见 `docs/troubleshooting.md` §21）。

默认 socket：`$TMPDIR/dsh-notify-macos.sock`（`os.tmpdir()`，在 macOS 上是 `/var/folders/…/T/` 这种长路径），
可用配置 `socketPath` 改。本文档示例为便于手敲统一写成 `/tmp/dsh-notify-macos.sock` —— 那需要你在配置里显式钉上该路径。

## 命令

| 命令 | 载荷 | 说明 | 回复 |
| --- | --- | --- | --- |
| `show` | `{sessionId, sessionTitle, title?, kind, message, detail?, turn?, ref?, action, url?, sound?, autoDismissSec?}` | 弹/合并一张卡片。`kind` = `completed` \| `error` \| `blocked`；`turn` = 该行的位置锚点；`ref` = 等待用户处理那一行的关联键 | 无（fire-and-forget） |
| `clear` | `{sessionId, ref}` | 用户已在 GUI 里处理掉 `ref` 对应的授权/提问 → 删掉那一行（删空则整卡消失，剩一行自动折叠） | `{"ok":true,"removed":0\|1,"remaining":N,"reason?":"no-card"\|"no-row"}` |
| `ping` | — | 存活探测 | `{"ok":true}` |
| `probe` | — | 守护进程健康探测 | `{"ok":true,"daemon":true}` |
| `peer` | — | 诊断：内核认定的**连接方 uid**（不是报文里自称的身份） | `{"ok":true,"uid":501}` |
| `build` | — | 诊断：**正在运行**的这份二进制内嵌的源码指纹（构建时写入，见 §28） | `{"ok":true,"fingerprint":"ebd718e6…"}` |
| `state` | — | 诊断：当前卡数/行数（不含正在消失的卡片） | `{"ok":true,"cards":N,"entries":M}` |
| `debug` | `{url, sessionId, sessionTitle?, turn?, focusOnly?}` | 手动触发一次跳转/聚焦（等价于点卡片，诊断用） | `{"ok":true,"driven":true\|false}` |

## 手动探测

```bash
# 存活
printf '{"cmd":"ping"}\n' | nc -U "$TMPDIR/dsh-notify-macos.sock"
# → {"ok":true}

# 当前卡片
printf '{"cmd":"state"}\n' | nc -U "$TMPDIR/dsh-notify-macos.sock"
# → {"ok":true,"cards":2,"entries":3}

# 跑着的这份二进制是哪次构建的（用来确认"装的是新产物、跑的也是新的"）
printf '{"cmd":"build"}\n' | nc -U "$TMPDIR/dsh-notify-macos.sock"
# → {"ok":true,"fingerprint":"ebd718e6…"}   与 bin/dsh-notify-server.fingerprint 应一致

# 这条连接在内核眼里是谁（用来确认 peer 校验读到的是真实 uid）
printf '{"cmd":"peer"}\n' | nc -U "$TMPDIR/dsh-notify-macos.sock"
# → {"ok":true,"uid":501}   （501 = 你自己的 uid；换个用户来连会被直接拒绝）

# 手动跳一次（会真的驱动浏览器）
printf '{"cmd":"debug","url":"http://127.0.0.1:3080","sessionId":"<会话 id>","turn":42}\n' \
  | nc -U "$TMPDIR/dsh-notify-macos.sock"
```

推一张测试卡片（`test/manual/push-anchors.py` 是现成的夹具，支持"一张卡多行、每行一个位置锚点"）：

```bash
python3 test/manual/push-anchors.py "$TMPDIR/dsh-notify-macos.sock" <会话 id> 120:最新 60:需翻页 1:最早
```

## 日志里能读到什么

守护进程日志固定写到 `/tmp/dsh-notify-macos.log`（不随 socketPath 走）：

| 行 | 含义 |
| --- | --- |
| `[show] kind=… session=… turn=… ref=…` | 收到一条卡片指令（host → daemon 的契约在这里可见） |
| `[jump] target=… (turn=N)` | 点击要跳的深链与位置锚点 |
| `[navigate] <浏览器> tab updated; hosting window raised` + `[jump] navigated tab in <浏览器> (delivered)` | 跳转已交给浏览器 |
| `[clear] removed ref=…; N row(s) left` / `no-row` / `no live card` | 琥珀行清理的结果（`no-row`/`no live card` 都是**正确的 no-op**，不误删） |
| `[cards] jump not delivered; row N kept so it can be retried` | 跳转没交出去 → 卡片保留（不会无声消失） |
| `[cards] snapshot loaded/restored …` | daemon 重启后的卡片恢复 |
| `[activate] …` | 抬窗口过程（评估"抬起来的窗口对不对"时看这行） |

## 信任边界（谁能连这个 socket）

守护进程**只服务同一个用户**（以及 root，见下）：socket 上的每一次连接都先用
`getpeereid()` 取内核给出的对端 uid，与守护进程自身 uid 比对，不是自己人就立刻关闭 ——
**连请求都不读**（对方的数据不进入解析器），并在 `/tmp/dsh-notify-macos.log` 记一行
`拒绝 uid=… 的连接`。

要挡的是同机其他普通用户：他们若能连上，就能往你的桌面推任意内容的卡片，并借你的权限
让浏览器跳转。三道防线：

| 防线 | 内容 |
| --- | --- |
| socket 权限 | bind 之后显式 `chmod 0600`（默认受 umask 影响，实测会是 `0755`） |
| 对端 uid | `getpeereid()` + `PeerPolicy`（`Sources/dshNotifyCore/PeerPolicy.swift`），**协议不变** |
| 快照权限 | `<socketPath>.cards.json` 写为 `0600`（里面有会话标题/路径，默认会是 `0644`） |

放行 root 是**有意的**：root 本来就能读本进程内存、杀掉它、直接读快照，拒绝它不增加任何
安全性，只会在有人用 `sudo` 脚本时变成查不出原因的故障面。策略写成纯函数并带单测，
改宽（比如"任何本地用户都放行"）会先让测试变红。

## 单实例与生命周期

- 守护进程**单实例**：第二个实例发现 socket 已被占用会直接退出；
- 对端中途挂断不会杀掉它（`SIGPIPE` 已忽略，见 §21）；
- host 半区（`lib/index.js`）在发送失败时会拉起守护进程并重试一次（`show` 与 `clear` 都如此）；
- socket 文件残留不影响启动（启动时会先 `unlink` 再 bind）。
