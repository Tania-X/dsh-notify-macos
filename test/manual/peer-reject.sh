#!/bin/bash
#
# peer-reject.sh — 验证「另一个 uid 连不上守护进程」（issue #32）。
#
# 为什么不在 CI：这条路径需要一个**真实的第二 uid**，CI 里造不出来；能自动化的部分
# （内核是否给出真实对端 uid、策略判定、socket/快照权限）已经在 test/socket-smoke.sh
# 与 XCTest 里钉住了。
# 为什么还要写成脚本：这类检查以前只存在于"我手工跑过一遍"的记忆里 —— 凡是人工验收，
# 都该留下一行可重复执行的命令（见 docs/troubleshooting.md §27）。
#
# 需要：无密码 sudo（`sudo -n true` 能过）+ 一个存在的其他用户（默认 _www）。
# 用法：test/manual/peer-reject.sh [守护进程二进制] [其他用户]
set -u
cd "$(dirname "$0")/../.."

BIN="${1:-bin/dsh-notify-server}"
OTHER="${2:-_www}"
SOCK="/tmp/dsh-peer-reject-$$.sock"
DAEMON_LOG="/tmp/dsh-notify-macos.log"   # 守护进程日志固定在这里（不随 socketPath 走）
PROBE="/tmp/dsh-peer-probe-$$.py"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; }

cleanup() {
  # kill 之后要 wait：否则 shell 退出时会打印一行 "Terminated"，看起来像构建/检查失败
  if [ -n "${DPID:-}" ]; then
    kill "$DPID" 2>/dev/null || true
    wait "$DPID" 2>/dev/null || true
  fi
  rm -f "$SOCK" "$PROBE"
}
trap cleanup EXIT

[ -x "$BIN" ] || { echo "binary missing: $BIN"; exit 2; }
if ! sudo -n true 2>/dev/null; then
  skip "需要无密码 sudo 才能切换 uid；本次未验证拒绝路径（这不是通过，只是没跑）"
  exit 0
fi
OTHER_UID=$(id -u "$OTHER" 2>/dev/null) || { echo "用户不存在: $OTHER"; exit 2; }
[ "$OTHER_UID" = "$(id -u)" ] && { echo "需要与当前 uid 不同的用户，$OTHER 就是自己"; exit 2; }

# 以其他 uid 发一帧的探针（放在 /tmp：别的用户读得到我们的工作目录才怪）
cat > "$PROBE" <<'PYEOF'
import socket, sys
sock, frame = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(sock)
except Exception as e:
    print("CONNECT-ERR:" + type(e).__name__)
    sys.exit(2)
s.sendall((frame + "\n").encode())
try:
    data = s.recv(4096)
except Exception:
    data = b""
print("REPLY:" + (data.decode().strip() if data else "<closed>"))
PYEOF
chmod 644 "$PROBE"

echo "== peer-reject: $BIN (socket $SOCK, 对端用户 $OTHER uid=$OTHER_UID, 我 uid=$(id -u)) =="
rm -f "$SOCK"
"$BIN" "$SOCK" >/dev/null 2>&1 &
DPID=$!

# 等守护进程开始服务
for _ in $(seq 1 20); do
  [ -S "$SOCK" ] && printf '{"cmd":"peer"}\n' | nc -U "$SOCK" 2>/dev/null | grep -q '"ok":true' && break
  sleep 0.3
done

MODE=$(stat -f "%Lp" "$SOCK" 2>/dev/null)
[ "$MODE" = "600" ] && ok "socket 是 0600（默认 umask 会给出 0755）" || bad "socket 权限是 ${MODE}，期望 600"

SELF=$(printf '{"cmd":"peer"}\n' | nc -U "$SOCK" 2>/dev/null)
[ "$SELF" = "{\"ok\":true,\"uid\":$(id -u)}" ] \
  && ok "同 uid 正常：$SELF" || bad "同 uid 请求异常：$SELF"

# 单独验证第二道防线：把 socket 放开成 666，让"文件权限"不再是解释
sudo -n chmod 0666 "$SOCK" || bad "chmod 0666 失败（无法单独验证 uid 判定）"
[ "$(stat -f "%Lp" "$SOCK")" = "666" ] && ok "已放开为 0666，接下来只有 uid 判定在挡" || bad "chmod 没生效"

# 探针必须用**会回复的**命令：`show` 是 fire-and-forget，"连接被关"根本区分不出
# "被拒绝"和"被接受但本来就没回复" —— 短路版（把 uid 判定临时改掉）实测过，这条
# 断言当时是假通过的（无齿断言）。
LOG_BEFORE=$(wc -c < "$DAEMON_LOG" 2>/dev/null || echo 0)
REPLY=$(sudo -n -u "$OTHER" python3 "$PROBE" "$SOCK" '{"cmd":"ping"}' | sed -n 's/^REPLY://p')
if [ "$REPLY" = "<closed>" ]; then
  ok "uid=$OTHER_UID 的 ping 没有回复（连接被直接关闭，请求没进解析器）"
elif [ -z "$REPLY" ]; then
  bad "探针没有输出（sudo/python 本身失败，本轮等于没测）"
else
  bad "uid=$OTHER_UID 竟然拿到了回复：$REPLY"
fi

# 再推一张卡：被拒的话它不该出现在卡片栈里
sudo -n -u "$OTHER" python3 "$PROBE" "$SOCK" \
  '{"cmd":"show","kind":"completed","message":"hacked"}' >/dev/null 2>&1
LEFT=$(printf '{"cmd":"state"}\n' | nc -U "$SOCK" 2>/dev/null)
echo "$LEFT" | grep -q '"cards":0' \
  && ok "被拒的 show 没有落地（state=${LEFT}）" || bad "被拒的 show 疑似生效：$LEFT"

# 只看本次新增的日志：上次运行的记录还留在文件里，tail 会给出粘住的假证据
LOG_NEW=$(tail -c "+$((LOG_BEFORE + 1))" "$DAEMON_LOG" 2>/dev/null)
if echo "$LOG_NEW" | grep -q "拒绝 uid=$OTHER_UID"; then
  ok "日志里留下了本次的拒绝记录（${DAEMON_LOG}）"
else
  bad "本次日志里没有拒绝记录（诊断是不是又走 print 了？新增内容：$(echo "$LOG_NEW" | tr '\n' '|' | head -c 200)）"
fi

AFTER=$(printf '{"cmd":"peer"}\n' | nc -U "$SOCK" 2>/dev/null)
[ "$AFTER" = "{\"ok\":true,\"uid\":$(id -u)}" ] \
  && ok "拒绝之后同 uid 仍然正常：$AFTER" || bad "同 uid 被误伤：$AFTER"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
