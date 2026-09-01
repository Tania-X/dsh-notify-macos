# dsh-notify-macos

DeepSeek Harness 插件：每次对话/任务完成后，在 MacBook 屏幕右上角弹出**常驻悬浮通知卡片**，让你即使把浏览器切到后台也能第一时间知道任务已完成。

## 效果

- 每个会话的对话轮次（turn）处理完毕时，弹出一张通知卡片，**悬停在右上角不自动消失**，直到你主动处理。
- **卡片会一直停留**，除非你：
  1. **将卡片向右拖拽** —— 直接清除它；
  2. **点击卡片** —— 跳转到任务完成的位置（默认在 Finder 中打开该会话的工作目录），同时清除它。
- **多任务同时完成**：支持同时弹出多张卡片，每张带**递增编号**，互不遮挡、可分别处理。
- 通知文案默认「任务已完成」，若会话已有标题则显示「任务已完成：<会话标题>」。

## 原理

两个部分组成：

1. **host 侧 Cordis 插件**（`lib/index.js`，Node.js 进程内）——监听 agent 作用域的 `agent/status` 事件，检测「running → idle」转换：
   - agent 在收到你的消息后进入 `running`；
   - 一个 agent 会保持 `running` 直到所有排队轮次全部处理完，才回到 `idle`；
   - 因此 `running → idle` 恰好对应「一轮完整对话结束」，每次只触发一次通知。
   - 检测到完成时，通过 **Unix domain socket**（`$TMPDIR/dsh-notify-macos.sock`）把事件推给守护进程。

2. **Swift/AppKit 守护进程**（`bin/dsh-notify-server`）——自绘右上角悬浮卡片：
   - 原生 `osascript` 通知无法悬停/拖拽，所以用 AppKit 无边框窗口自绘，置顶于所有空间；
   - 拖拽右移超过阈值 → 动画滑出并清除；
   - 点击 → 执行跳转动作（Finder 打开工作目录 / 打开 Web UI / 无动作），然后清除；
   - 卡片堆叠从右上角向下排列，每张带编号徽标；
   - 插件首次使用时自动拉起守护进程（detached），之后常驻。

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
| `clickAction` | string | `"open-folder"` | 点击卡片的行为：`open-folder`（Finder 打开会话工作目录）/ `open-web`（浏览器打开 Web UI）/ `none`（仅清除） |
| `webUrl` | string | `"http://127.0.0.1:3080"` | `clickAction: open-web` 时打开的地址 |
| `autoDismissSec` | number | `0` | 卡片自动消失秒数；`0`（默认）常驻直到你拖拽/点击 |
| `socketPath` | string | `$TMPDIR/dsh-notify-macos.sock` | 守护进程 socket 路径 |
| `serverPath` | string | 插件包内 `bin/dsh-notify-server` | 守护进程二进制路径 |

示例：

```yaml
- insert:
    - id: notify-macos
      name: ./plugins/dsh-notify-macos/lib/index.js?v=3
      config:
        enabled: true
        title: DeepSeek Harness
        message: 任务已完成：{title}
        sound: true
        rootOnly: true
        clickAction: open-folder
        autoDismissSec: 0
```

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
| `show` | `{title, message, action, path, url, sound, autoDismissSec}` | 弹出一张卡片 |
| `ping` | — | 存活探测，回复 `{"ok":true}` |

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
