#!/usr/bin/env python3
"""位置索引跳转的边界测试夹具：一张聚合卡、多行、每行一个历史锚点。

同一 sessionId 的 show 帧会聚合成 ONE card；本脚本给每一行下发**不同的
turn**，所以展开后点第 N 行应当滚到那一行自己的完成位置，而不是都跳最新。

用法:
    test/manual/push-anchors.py <socket> <sessionId> <turn>[:<标签>] ...

例子（窗口内 / 窗口外 / 极早 / 不存在的 turn）:
    test/manual/push-anchors.py /tmp/dsh-notify-macos.sock \\
        session-xxx 101:窗口内-最新 95:窗口内-稍旧 60:窗口外-需翻页 \\
        1:最早 9999:不存在-应回退

推送后：展开卡片（点标题/▾），逐行点击，每点一行该行消失且浏览器滚到
那一行的位置；最后一行点掉后卡片自动消失（或向右拖走整张卡）。
"""
import json
import socket
import sys


def send(sock_path, payload, expect_reply=True):
    """Send one request line.

    `show` is fire-and-forget by design (the daemon handles it on the main
    thread and never writes a reply — see `processLine`), so waiting for one
    just burns the timeout; only `state`/`ping` answer.
    """
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3 if expect_reply else 1)
    try:
        s.connect(sock_path)
        # The daemon treats a request as complete only at a newline
        # (`if buffer.contains(0x0A) { break }`): without it the daemon blocks
        # in read() until the peer closes, so the caller sees a bogus timeout
        # and the request is only processed on EOF.
        s.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())
        if not expect_reply:
            return "sent"
        return s.recv(4096).decode().strip() or "(no reply)"
    except socket.timeout:
        return "timeout (no reply)"
    except Exception as exc:  # noqa: BLE001 - 诊断输出用
        return "ERR %s" % exc
    finally:
        s.close()


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    sock_path, session_id, specs = argv[1], argv[2], argv[3:]
    for spec in specs:
        turn_text, _, label = spec.partition(":")
        try:
            turn = int(turn_text)
        except ValueError:
            print("跳过非法 turn: %s" % spec)
            continue
        message = "锚点 turn=%d%s" % (turn, "（%s）" % label if label else "")
        reply = send(sock_path, {
            "cmd": "show",
            "kind": "completed",
            "sessionId": session_id,
            "sessionTitle": "位置索引边界测试",
            "message": message,
            "turn": turn,
            "sound": False,
        }, expect_reply=False)
        print("turn=%-5d %s -> %s" % (turn, message, reply))
    print(send(sock_path, {"cmd": "state"}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
