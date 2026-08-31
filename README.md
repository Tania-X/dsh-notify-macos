# dsh-notify-macos

DeepSeek Harness 插件：每次对话/任务完成后，在 MacBook 屏幕右上角弹出一次原生 macOS 通知，让你即使把浏览器切到后台也能第一时间知道任务已完成。

## 效果

- 每个会话的对话轮次（turn）处理完毕时，弹出一次通知。
- 通知出现在 macOS 通知中心（默认右上角），与应用是否在前台无关。
- 通知文案默认「任务已完成」，若会话已有标题则显示「任务已完成：<会话标题>」。

## 原理

这是一个 **host 侧（Node.js 进程内）Cordis 插件**，通过监听 agent 作用域的 `agent/status` 事件来检测「running → idle」转换：

- agent 在收到你的消息后进入 `running`；
- 一个 agent 会保持 `running` 直到所有排队轮次全部处理完，才回到 `idle`；
- 因此 `running → idle` 恰好对应「一轮完整对话结束」，每次只触发一次通知。

触发时通过系统自带 `osascript -e 'display notification …'` 弹出原生 macOS 通知，无需任何第三方依赖。

## 安装（已完成）

插件已安装到 web profile 并热加载（无需重启，`cordis.patch.yml` 由 HMR 监听）：

```
$DSH_HOME/profiles/web/plugins/dsh-notify-macos/lib/index.js
$DSH_HOME/profiles/web/cordis.patch.yml   # 追加了 notify-macos 条目
```

验证加载状态：

```bash
curl -s -X POST http://127.0.0.1:3080/api/pluginInventory/list \
  -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v1","method":"pluginInventory/list","payload":{"args":{}}}'
# 应看到 include:notify-macos ... active
```

## 配置

在 `$DSH_HOME/profiles/web/cordis.patch.yml` 中修改 `notify-macos` 条目的 `config`：

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | 总开关 |
| `title` | string | `"DeepSeek Harness"` | 通知标题 |
| `message` | string | `"任务已完成"` | 通知正文；含 `{title}` 时替换为会话标题 |
| `sound` | boolean | `false` | 是否播放系统提示音（Glass） |
| `rootOnly` | boolean | `true` | 仅顶层会话完成时通知；`false` 则子代理（subagent）完成也会通知（工作流大量扇出子代理时可能较吵） |

示例：

```yaml
- insert:
    - id: notify-macos
      name: ./plugins/dsh-notify-macos/lib/index.js
      config:
        enabled: true
        title: DeepSeek Harness
        message: 任务已完成：{title}
        sound: true
        rootOnly: true
```

修改保存后由 HMR 自动生效。

## 卸载

1. 删除 `cordis.patch.yml` 中的 `notify-macos` 条目（恢复为 `[]`）；
2. 删除 `$DSH_HOME/profiles/web/plugins/dsh-notify-macos/` 目录；
3. 可选：重启 `dsh web` 确保完全清理。

## 开发源码

本插件源码位于工作区 `dsh-notify-macos/`（本目录），安装位置是 `$DSH_HOME/profiles/web/plugins/`。改动源码后同步安装：

```bash
cp -R lib/ "$DSH_HOME/profiles/web/plugins/dsh-notify-macos/lib/"
```

## 平台要求

- 仅 macOS（通过 `process.platform === "darwin"` 判断；其他平台会记录一条 warn 日志并禁用）。
- 需要系统允许 `osascript`（macOS 自带，无需额外权限）。
