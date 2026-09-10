#!/bin/bash
#
# socket-smoke.sh — daemon 协议级冒烟基线（L2 行为锁定用）。
#
# 用途：在结构拆分（SwiftPM PR-A）前后各跑一次，结果必须一致：
#   - daemon 能起、能 ping/probe、能吞下各种 show 帧（含合并/异常 kind/无 sessionId）
#   - 连续 N 帧后进程仍存活、可干净退出
#   - 单实例语义：第二个 daemon 因 socket 被占应自行退出
#
# 注意：本脚本不做跳转/debug（会驱动真 Safari），视觉卡片是否正常由人确认；
#       状态机语义（聚合/优先级/文案）由 PR-B 的 XCTest 固化。
# 用法: test/socket-smoke.sh [daemon-binary]
set -u
BIN="${1:-bin/dsh-notify-server}"
SOCK="/tmp/dsh-notify-smoke.sock"
LOG="/tmp/dsh-notify-smoke.log"
CARDS="/tmp/dsh-notify-smoke.sock.cards.json"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# py FRAMES_JSON — send frames over the socket, print each reply line.
py() {
  python3 - "$SOCK" "$1" <<'PYEOF'
import json, socket, sys
sock_path, frames = sys.argv[1], json.loads(sys.argv[2])
for obj in frames:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect(sock_path)
        s.sendall((json.dumps(obj) + "\n").encode())
        try:
            data = s.recv(4096).decode().strip()
        except Exception:
            data = ""
        s.close()
        print(data or "<empty>")
    except Exception as e:
        print("CONN-ERR:" + str(e))
PYEOF
}

# jget JSON FIELD — print one field of a JSON reply.
jget() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

echo "== smoke: $BIN (socket $SOCK) =="
[ -x "$BIN" ] || { echo "binary missing: $BIN"; exit 2; }
rm -f "$SOCK" "$LOG" "$CARDS"

# --- start daemon ---
"$BIN" "$SOCK" >"$LOG" 2>&1 &
DPID=$!
sleep 1.2
kill -0 "$DPID" 2>/dev/null && ok "daemon started (pid $DPID)" || bad "daemon failed to start"

# --- second instance must exit (socket held) ---
"$BIN" "$SOCK" >"$LOG.dup" 2>&1 &
DUP=$!
sleep 1.0
if kill -0 "$DUP" 2>/dev/null; then bad "second daemon still running (should exit)"; kill "$DUP" 2>/dev/null; else ok "single-instance guard (dup exited)"; fi

# --- ping / probe ---
R=$(py '[{"cmd":"ping"},{"cmd":"probe"}]')
if [ -n "$R" ] && ! echo "$R" | grep -q CONN-ERR && echo "$R" | grep -q '"ok":true'; then
  ok "ping+probe reply ok"
else
  bad "ping/probe: $R"
fi

# --- show frames: merge, kinds, degenerate inputs ---
R=$(py '[{"cmd":"show","kind":"completed","sessionId":"smoke-a","sessionTitle":"A","message":"done","sound":false},
         {"cmd":"show","kind":"completed","sessionId":"smoke-a","sessionTitle":"A","message":"done again","sound":false},
         {"cmd":"show","kind":"error","sessionId":"smoke-b","sessionTitle":"B","message":"boom","detail":"err","sound":false},
         {"cmd":"show","kind":"blocked","sessionId":"smoke-c","sessionTitle":"C","message":"wait","detail":"tool-x","sound":false},
         {"cmd":"show","kind":"weird-kind","sessionId":"smoke-d","message":"x","sound":false},
         {"cmd":"show","sessionId":"smoke-e","sound":false},
         {"cmd":"show","message":"no session","sound":false}]')
if ! echo "$R" | grep -q CONN-ERR; then
  ok "7 show frames accepted (merge/kinds/degenerate)"
else
  bad "a show frame failed: $R"
fi

sleep 0.6
kill -0 "$DPID" 2>/dev/null && ok "daemon alive after frames" || bad "daemon died after frames"

# --- diagnostic state: 6 cards / 7 entries as pushed above ---
S1=$(py '[{"cmd":"state"}]')
C1=$(jget "$S1" cards); E1=$(jget "$S1" entries)
if [ "$C1" = "6" ] && [ "$E1" = "7" ]; then
  ok "state reports 6 cards / 7 entries"
else
  bad "state mismatch: $S1"
fi

# --- persistence: cards must survive a daemon restart ---
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
"$BIN" "$SOCK" >"$LOG.restart" 2>&1 &
DPID=$!
sleep 1.2
S2=$(py '[{"cmd":"state"}]')
C2=$(jget "$S2" cards); E2=$(jget "$S2" entries)
if [ "$C2" = "$C1" ] && [ "$E2" = "$E1" ] && [ -n "$C2" ]; then
  ok "cards restored after restart ($C2 cards / $E2 entries)"
else
  bad "restore mismatch: before=$S1 after=$S2"
fi

# --- clean shutdown ---
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
rm -f "$SOCK" "$CARDS"
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
