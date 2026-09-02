# dsh-notify-macos

DeepSeek Harness 插件：每次对话/任务完成后，在 MacBook 屏幕右上角弹出**常驻悬浮通知卡片**，让你即使把浏览器切到后台也能第一时间知道任务已完成。

## 效果

- 每个会话的对话轮次（turn）处理完毕时，弹出一张通知卡片，**悬停在右上角不自动消失**，直到你主动处理。
- **卡片会一直停留**，除非你：
  1. **将卡片向右拖拽** —— 直接清除它；
  2. **点击卡片** —— 跳转到该任务完成的位置（浏览器打开 Web UI 并直接定位到该会话的「任务完成」消息处），同时清除它。
- **多任务同时完成**：支持同时弹出多张卡片，每张带**递增编号**，互不遮挡、可分别处理。
- 通知文案默认「任务已完成」，若会话已有标题则显示「任务已完成：<会话标题>」。

## 原理

两个部分组成：

1. **host 侧 Cordis 插件**（`lib/index.js`，Node.js 进程内）——监听 agent 作用域的 `agent/status` 事件，检测「running → idle」转换：
   - agent 在收到你的消息后进入 `running`；
   - 一个 agent 会保持 `running` 直到所有排队轮次全部处理完，才回到 `idle`；
   - 因此 `running → idle` 恰好对应「一轮完整对话结束」，每次只触发一次通知。
   - 检测到完成时，通过 **Unix domain socket**（`$TMPDIR/dsh-notify-macos.sock`）把事件（含会话 id）推给守护进程。

2. **Swift/AppKit 守护进程**（`bin/dsh-notify-server`）——自绘右上角悬浮卡片：
   - 原生 `osascript` 通知无法悬停/拖拽，所以用 AppKit 无边框窗口自绘，置顶于所有空间；
   - 拖拽右移超过阈值 → 动画滑出并清除；
   - 点击 → 执行跳转动作，然后清除；
   - 卡片堆叠从右上角向下排列，每张带编号徽标；
   - 插件首次使用时自动拉起守护进程（detached），之后常驻。

**点击跳转（`jump-web`，默认）如何定位到「任务完成」处**：守护进程通过 AppleScript 控制浏览器（Chrome 优先，Safari 备选），把 `localStorage["dsh.sessions.current"]` 指向目标会话并刷新页面。Web UI 启动时会读取该键打开对应会话，而会话内滚动锚点是内存态的、刷新即清空，因此会自动滚动到最新消息——也就是「任务完成」的位置。即使你当时在别的会话、别的页面甚至别的应用里，画面都会被带过去。

守护进程不可用时（例如二进制缺失），插件自动回退到 `osascript` 弹一次系统通知，保证任务完成不会被静默丢弃。

## 安装（已完成）

插件已安装到 web profile 并热加载（`cordis.patch.yml` 由 HMR 监听，改配置即时生效；改代码需将 `name` 的 `?v=` 版本号 +1 强制重载，或重启 `dsh web`）：

```
$DSH_HOME/profiles/web/plugins/dsh-notify-macos/lib/index.js        # 插件
$DSH_HOME/profiles/web/plugins/dsh-notify-macos/bin/dsh-notify-server   # Swift 守护进程
$DSH_HOME/profiles/web/cordis.patch.yml   # notify-macos 条目
```

验证加载状态：

```bash
curl -s -X POST http://127.0.0.1:3080/api/pluginInventory/list \
  -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v1","method":"pluginInventory/list","payload":{"args":{}}}'
# 应看到 include:notify-macos ... active
```

验证守护进程：

```bash
ls -l $TMPDIR/dsh-notify-macos.sock   # 插件自动拉起后应存在
echo '{"cmd":"ping"}' | nc -U $TMPDIR/dsh-notify-macos.sock  # 返回 {"ok":true}
```

## 配置

在 `$DSH_HOME/profiles/web/cordis.patch.yml` 中修改 `notify-macos` 条目的 `config`：

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | 总开关 |
| `title` | string | `"DeepSeek Harness"` | 卡片标题行 |
| `message` | string | `"任务已完成"` | 卡片正文；含 `{title}` 时替换为会话标题 |
| `sound` | boolean | `false` | 是否播放系统提示音（Glass） |
| `rootOnly` | boolean | `true` | 仅顶层会话完成时通知；`false` 则子代理（subagent）完成也会通知（工作流大量扇出子代理时可能较吵） |
| `clickAction` | string | `"jump-web"` | 点击卡片的行为：`jump-web`（浏览器打开 Web UI 并定位到该会话的「任务完成」处）/ `open-folder`（Finder 打开会话工作目录）/ `open-web`（仅打开 Web UI，不定位会话）/ `none`（仅清除） |
| `webUrl` | string | `"http://127.0.0.1:3080"` | `clickAction: open-web / jump-web` 时打开的地址 |
| `autoDismissSec` | number | `0` | 卡片自动消失秒数；`0`（默认）常驻直到你拖拽/点击 |
| `socketPath` | string | `$TMPDIR/dsh-notify-macos.sock` | 守护进程 socket 路径 |
| `serverPath` | string | 插件包内 `bin/dsh-notify-server` | 守护进程二进制路径 |

示例：

```yaml
- insert:
    - id: notify-macos
      name: ./plugins/dsh-notify-macos/lib/index.js?v=4
      config:
        enabled: true
        title: DeepSeek Harness
        message: 任务已完成：{title}
        sound: true
        rootOnly: true
        clickAction: jump-web
        autoDismissSec: 0
```

## 一次性授权（点击跳转需要）

`jump-web` 通过 AppleScript 控制浏览器，首次点击卡片时 macOS 会弹出自动化授权确认（「dsh-notify-server 想要控制 Google Chrome / Safari」），**点「允许」即可**，之后永久生效。若没有看到弹窗或跳转失效，请按浏览器处理：

- **Chrome**：菜单 View → Developer → 勾选 **Allow JavaScript from Apple Events**。
- **Safari**：需先在 设置 → 高级 开启「显示开发菜单」，然后 开发 → 勾选 **允许 JavaScript 从 Apple Events**。

验证授权状态（守护进程会回复浏览器是否可脚本化）：

```bash
echo '{"cmd":"probe"}' | nc -U $TMPDIR/dsh-notify-macos.sock
# 期望 {"ok":true,"chrome":true,"safari":true}
```

即使未授权，点击也会退化为「打开 Web UI 标签页」（不会精确跳转会话）。

## 卸载

1. 删除 `cordis.patch.yml` 中的 `notify-macos` 条目（恢复为 `[]`）；
2. 删除 `$DSH_HOME/profiles/web/plugins/dsh-notify-macos/` 目录；
3. 结束守护进程：`pkill -f dsh-notify-server`；
4. 删除 socket 文件：`rm -f $TMPDIR/dsh-notify-macos.sock`。

## 开发

### 重新编译守护进程

```bash
cd bin
swiftc -O dsh-notify-server.swift -o dsh-notify-server
```

### 协议（socket，JSON Lines）

| 命令 | 载荷 | 说明 |
| --- | --- | --- |
| `show` | `{title, message, action, path, url, sessionId, sound, autoDismissSec}` | 弹出一张卡片 |
| `ping` | — | 存活探测，回复 `{"ok":true}` |
| `probe` | — | 探测浏览器自动化授权，回复 `{"ok":true,"chrome":…,"safari":…}` |

### 手动测试

```bash
./bin/dsh-notify-server /tmp/dsh-notify-test.sock &   # 启动守护进程
python3 -c "
import socket,json
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('/tmp/dsh-notify-test.sock')
s.sendall((json.dumps({'cmd':'show','title':'DeepSeek Harness','message':'测试卡片','action':'open-folder','path':'/Users/apple/dsh'})+'\n').encode())
s.close()
"
```

## 平台要求

- 仅 macOS（插件通过 `process.platform === "darwin"` 判断；其他平台记录 warn 并禁用）。
- 守护进程需要 Swift 5.9+ 编译（本机已编译好二进制，无需额外工具链）。
- 需要系统允许创建置顶悬浮窗口（无需特殊权限）。
