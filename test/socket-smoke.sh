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
R=$(py '[{"cmd":"show","kind":"completed","sessionId":"smoke-a","sessionTitle":"A","message":"done","turn":11,"sound":false},
         {"cmd":"show","kind":"completed","sessionId":"smoke-a","sessionTitle":"A","message":"done again","turn":12,"sound":false},
         {"cmd":"show","kind":"error","sessionId":"smoke-b","sessionTitle":"B","message":"boom","detail":"err","sound":false},
         {"cmd":"show","kind":"blocked","sessionId":"smoke-c","sessionTitle":"C","message":"wait","detail":"tool-x","sound":false},
         {"cmd":"show","kind":"weird-kind","sessionId":"smoke-d","message":"x","sound":false},
         {"cmd":"show","sessionId":"smoke-e","sound":false},
         {"cmd":"show","sessionId":"smoke-turn","sessionTitle":"T","message":"m","turn":5,"sound":false},
         {"cmd":"show","message":"no session","sound":false}]')
if ! echo "$R" | grep -q CONN-ERR; then
  ok "8 show frames accepted (merge/kinds/degenerate/turn)"
else
  bad "a show frame failed: $R"
fi

sleep 0.6
kill -0 "$DPID" 2>/dev/null && ok "daemon alive after frames" || bad "daemon died after frames"

# --- diagnostic state: 6 cards / 7 entries as pushed above ---
S1=$(py '[{"cmd":"state"}]')
C1=$(jget "$S1" cards); E1=$(jget "$S1" entries)
if [ "$C1" = "7" ] && [ "$E1" = "8" ]; then
  ok "state reports 7 cards / 8 entries"
else
  bad "state mismatch: $S1"
fi

# --- the turn anchor must be persisted (position-indexed jump survives restart) ---
if grep -q '"turn" : 5\|"turn": 5\|"turn" : 5' "$CARDS" 2>/dev/null || grep -q '"turn"' "$CARDS" 2>/dev/null; then
  ok "turn anchor persisted in the snapshot"
else
  bad "turn anchor missing from snapshot"
fi

# --- EVERY merged row keeps its own anchor (position-indexed jumps) ---
ROWTURNS=$(python3 - "$CARDS" <<'PYEOF2'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print("unreadable: %s" % exc)
    raise SystemExit(0)
for card in data.get("cards", []):
    if card.get("sessionId") == "smoke-a":
        print("card=%s rows=%s" % (card.get("turn"), [e.get("turn") for e in card.get("entries", [])]))
        break
else:
    print("smoke-a card missing")
PYEOF2
)
if [ "$ROWTURNS" = "card=12 rows=[11, 12]" ]; then
  ok "per-row turn anchors persisted (merged card: $ROWTURNS)"
else
  bad "per-row turn anchors wrong: $ROWTURNS"
fi

# --- 对端在读回复前挂断：守护进程必须活着（SIGPIPE 曾把它静默杀死）---
# 复现真实事故：请求没带结尾换行时，daemon 会阻塞在 read() 直到对端关闭，
# 然后才处理请求并写回复 —— 此时 fd 已失效。没有 SIGPIPE 防护就是“凭空消失”。
python3 - "$SOCK" <<'PYEOF2'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sys.argv[1])
s.sendall(json.dumps({"cmd": "ping"}).encode())   # 故意不带 \n
s.close()                                        # 直接挂断
PYEOF2
sleep 0.5
kill -0 "$DPID" 2>/dev/null && ok "daemon survives a peer that hangs up mid-request (SIGPIPE)" \
  || bad "daemon died on a peer hang-up (missing SIGPIPE guard)"

# --- 琥珀卡片：用户在 GUI 里处理完 → clear 按 ref 精确删行/删卡 ---
R=$(py '[{"cmd":"show","kind":"blocked","sessionId":"smoke-clear","sessionTitle":"CLR","message":"wait-1","detail":"bash","ref":"approval:r1","sound":false},
         {"cmd":"show","kind":"blocked","sessionId":"smoke-clear","sessionTitle":"CLR","message":"wait-2","detail":"ask_user_question","ref":"ask:r2","sound":false}]')
if ! echo "$R" | grep -q CONN-ERR; then
  ok "2 blocked frames carrying refs accepted"
else
  bad "blocked frames failed: $R"
fi
for _ in $(seq 1 15); do
  grep -q '"ref" : "approval:r1"' "$CARDS" 2>/dev/null && break
  sleep 0.2
done
if grep -q '"ref" : "approval:r1"' "$CARDS" 2>/dev/null; then
  ok "blocked correlation key persisted in the snapshot"
else
  bad "blocked ref missing from the snapshot"
fi

# 未知 ref：必须什么都不做（不能误删别的行）
C=$(py '[{"cmd":"clear","sessionId":"smoke-clear","ref":"approval:nope"}]')
if [ "$(jget "$C" removed)" = "0" ] && [ "$(jget "$C" reason)" = "no-row" ]; then
  ok "clear with an unknown ref is a no-op"
else
  bad "unknown-ref clear misbehaved: $C"
fi

# 未知 session：同样什么都不做
C=$(py '[{"cmd":"clear","sessionId":"no-such-session","ref":"approval:r1"}]')
if [ "$(jget "$C" removed)" = "0" ] && [ "$(jget "$C" reason)" = "no-card" ]; then
  ok "clear for an unknown session is a no-op"
else
  bad "unknown-session clear misbehaved: $C"
fi

# 删第一条：只掉那一行，另一行仍在（琥珀→琥珀 收窄）
C=$(py '[{"cmd":"clear","sessionId":"smoke-clear","ref":"approval:r1"}]')
if [ "$(jget "$C" removed)" = "1" ] && [ "$(jget "$C" remaining)" = "1" ]; then
  ok "clear removes exactly the matching row (1 left)"
else
  bad "clear did not remove the matching row: $C"
fi

# 删最后一条：整张卡消失（动画结束后从栈里移除）
C=$(py '[{"cmd":"clear","sessionId":"smoke-clear","ref":"ask:r2"}]')
if [ "$(jget "$C" removed)" = "1" ] && [ "$(jget "$C" remaining)" = "0" ]; then
  ok "clearing the last blocked row empties the card"
else
  bad "clearing the last row misbehaved: $C"
fi
# 卡片是动画结束后才从栈里移除的：有界轮询而不是固定 sleep（固定等待在慢机器上会 flaky）
S2=""
for _ in $(seq 1 15); do
  S2=$(py '[{"cmd":"state"}]')
  [ "$(jget "$S2" cards)" = "7" ] && [ "$(jget "$S2" entries)" = "8" ] && break
  sleep 0.3
done
if [ "$(jget "$S2" cards)" = "7" ] && [ "$(jget "$S2" entries)" = "8" ]; then
  ok "cleared card is gone from the stack (back to 7 cards / 8 entries)"
else
  bad "stack counts after clear: $S2"
fi

# --- 竞态：卡片正在飞出时，同会话的新完成必须拿到自己的新卡 ---
# （dismiss 动画期间卡片仍在栈里；若被复用，通知会画在即将消失的窗口上）
py '[{"cmd":"show","kind":"completed","sessionId":"smoke-race","sessionTitle":"RACE","message":"first","ref":"race:a","sound":false},
     {"cmd":"show","kind":"blocked","sessionId":"smoke-race","sessionTitle":"RACE","message":"wait","ref":"race:b","sound":false}]' >/dev/null
# 腾出这张卡的最后一行为 completed，再把它删掉 → 卡片进入 0.34s 的飞出动画
py '[{"cmd":"clear","sessionId":"smoke-race","ref":"race:b"}]' >/dev/null
C=$(py '[{"cmd":"clear","sessionId":"smoke-race","ref":"race:a"}]')
if [ "$(jget "$C" remaining)" = "0" ]; then
  ok "race setup: card is mid-dismiss (0 rows left)"
else
  bad "race setup failed: $C"
fi
# 正在飞出时又来一条同会话完成 → 必须新建卡，不能被并进那张将死的卡
py '[{"cmd":"show","kind":"completed","sessionId":"smoke-race","sessionTitle":"RACE","message":"after-dismiss","ref":"race:c","sound":false}]' >/dev/null
# 断言必须看**动画结束后**的状态：飞出中的卡片仍在栈里，所以窗口内的 cards 计数
# 在修复前后都是 8（假阳性）。有区分度的是 entries ——
#   修复后：新卡保留 → 8 卡 / 9 行（原卡的飞行结束后只剩新卡）
#   未修复：并进将死的卡 → 动画结束整卡消失 → 7 卡 / 8 行
for _ in $(seq 1 15); do
  sleep 0.3
  S3=$(py '[{"cmd":"state"}]')
  [ "$(jget "$S3" cards)" = "8" ] && [ "$(jget "$S3" entries)" = "9" ] && break
done
if [ "$(jget "$S3" cards)" = "8" ] && [ "$(jget "$S3" entries)" = "9" ]; then
  ok "a completion arriving while a card flies out gets its own card (entries=9, not swallowed)"
else
  bad "dismiss-race: expected 8 cards / 9 entries, got $S3"
fi
# 自清理：把那张新卡也删掉，栈回到基线（否则会带偏后面的重启断言）
py '[{"cmd":"clear","sessionId":"smoke-race","ref":"race:c"}]' >/dev/null
for _ in $(seq 1 15); do
  S4=$(py '[{"cmd":"state"}]')
  [ "$(jget "$S4" cards)" = "7" ] && [ "$(jget "$S4" entries)" = "8" ] && break
  sleep 0.2
done
if [ "$(jget "$S4" cards)" = "7" ] && [ "$(jget "$S4" entries)" = "8" ]; then
  ok "race cards cleaned up (stack back to baseline)"
else
  bad "race cleanup left the stack at: $S4"
fi

# --- 同会话旧卡正在移出时，clear 必须命中新卡（否则目标行永远删不掉）---
# 场景：旧卡被清空 → 开始移出；此时同会话又来一条琥珀行 → show 会另起新卡；
# 用户处理完这条 → clear 必须删掉 NEW 卡上的那行（而不是空掉的旧卡 → no-row）。
py '[{"cmd":"show","kind":"completed","sessionId":"smoke-stale","sessionTitle":"STALE","message":"one","ref":"stale:1","sound":false},
     {"cmd":"show","kind":"completed","sessionId":"smoke-stale","sessionTitle":"STALE","message":"two","ref":"stale:2","sound":false}]' >/dev/null
py '[{"cmd":"clear","sessionId":"smoke-stale","ref":"stale:2"}]' >/dev/null   # 1 行
py '[{"cmd":"clear","sessionId":"smoke-stale","ref":"stale:1"}]' >/dev/null   # 0 行 → 开始移出
# 同会话新琥珀行：应落到一张新卡上（show 已跳过 dismissing）
py '[{"cmd":"show","kind":"blocked","sessionId":"smoke-stale","sessionTitle":"STALE","message":"handle me","ref":"stale:3","sound":false}]' >/dev/null
C=$(py '[{"cmd":"clear","sessionId":"smoke-stale","ref":"stale:3"}]')
if [ "$(jget "$C" removed)" = "1" ]; then
  ok "clear reaches the NEW card while the old one is still flying out"
else
  bad "clear hit the dismissing card instead of the new one: $C"
fi
for _ in $(seq 1 15); do
  S6=$(py '[{"cmd":"state"}]')
  [ "$(jget "$S6" cards)" = "7" ] && [ "$(jget "$S6" entries)" = "8" ] && break
  sleep 0.3
done
if [ "$(jget "$S6" cards)" = "7" ] && [ "$(jget "$S6" entries)" = "8" ]; then
  ok "stale-card scenario left the stack at baseline"
else
  bad "stack after stale-card scenario: $S6"
fi

# --- 飞行期间发生 relayout，快照里不得出现 0 行的空卡 ---
# （卡片飞出时仍留在栈里；此时任何 relayout 都会触发 persist，旧实现会把
#   这张已经被点空、正在飞走的卡写进快照，重启后变成一张空卡）
py '[{"cmd":"show","kind":"completed","sessionId":"smoke-empty","sessionTitle":"EMPTY","message":"solo","ref":"empty:a","sound":false}]' >/dev/null
py '[{"cmd":"clear","sessionId":"smoke-empty","ref":"empty:a"}]' >/dev/null       # 0 行 → 开始飞出
py '[{"cmd":"show","kind":"completed","sessionId":"smoke-other","sessionTitle":"OTHER","message":"trigger-relayout","ref":"other:b","sound":false}]' >/dev/null
sleep 0.8
if grep -q '"sessionId" : "smoke-empty"' "$CARDS" 2>/dev/null; then
  bad "a rowless card was persisted during the dismiss flight"
else
  ok "no rowless card in the snapshot (mid-dismiss relayout)"
fi
py '[{"cmd":"clear","sessionId":"smoke-other","ref":"other:b"}]' >/dev/null
for _ in $(seq 1 15); do
  S5=$(py '[{"cmd":"state"}]')
  [ "$(jget "$S5" cards)" = "7" ] && [ "$(jget "$S5" entries)" = "8" ] && break
  sleep 0.3
done
if [ "$(jget "$S5" cards)" = "7" ] && [ "$(jget "$S5" entries)" = "8" ]; then
  ok "mid-dismiss relayout left the stack at baseline"
else
  bad "stack after mid-dismiss relayout: $S5"
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
