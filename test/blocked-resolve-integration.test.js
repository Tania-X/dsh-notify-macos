/**
 * host ↔ daemon 集成测试（真 socket，不 mock 协议层）。
 *
 * 用一个临时 unix socket 假扮 daemon，驱动真实的 `apply()`：
 *   1. approval/asked        -> show 帧（带 ref=approval:<id>）
 *   2. approval/decided      -> clear 帧（同 ref）  ← 卡片该消失了
 *   3. tool/call(ask) -> tool/result -> clear 帧（ref=ask:<callId>）
 *   4. 无关的 tool/result    -> 不发 clear（每个普通工具调用都会产生它）
 * 纯函数单测见 blocked-resolve.test.js；这里验证的是"接线接没接对"。
 */
import { afterEach, describe, expect, it } from "vitest";
import net from "node:net";
import fs from "node:fs";
import { apply } from "../lib/index.js";

const sockets = [];

/** Start a fake daemon on a private unix socket; collect the frames it gets. */
async function fakeDaemon() {
  // Short path on purpose: a unix socket address is capped (~104 bytes) and
  // macOS' os.tmpdir() is long enough to blow past it (the connect then fails
  // silently and the test looks like the wiring is broken).
  const socketPath = `/tmp/dsh-notify-it-${process.pid}-${sockets.length}.sock`;
  const frames = [];
  const waiters = [];
  const server = net.createServer((conn) => {
    let buffer = "";
    conn.on("data", (chunk) => {
      buffer += chunk.toString();
      let index;
      while ((index = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        try {
          frames.push(JSON.parse(line));
        } catch {
          frames.push({ parseError: line });
        }
        for (const wake of waiters.splice(0)) wake();
      }
    });
    conn.on("error", () => {});
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  sockets.push({ server, socketPath });
  return {
    socketPath,
    frames,
    /**
     * Await until `count` frames of `cmd` arrived (or time out).
     *
     * Counting a COMMAND, not raw frames: the plugin pre-warms the daemon with a
     * `ping` right after apply(), so "one frame has arrived" is satisfied by the
     * ping long before the notification does.
     */
    async waitFor(cmd, count = 1) {
      const matching = () => frames.filter((f) => f.cmd === cmd).length;
      const deadline = Date.now() + 2000;
      while (matching() < count && Date.now() < deadline) {
        await new Promise((resolve) => {
          waiters.push(resolve);
          setTimeout(resolve, 20);
        });
      }
      return frames;
    },
    of(cmd) {
      return frames.filter((f) => f.cmd === cmd);
    },
  };
}

/** Minimal plugin ctx: capture the session/event handler apply() registers. */
function fakeCtx() {
  const handlers = {};
  return {
    handlers,
    ctx: {
      on(name, fn) {
        handlers[name] = fn;
      },
      sessionTitle: { get: () => ({ title: "Test Session" }) },
      logger: { warn() {}, info() {}, debug() {} },
    },
  };
}

function configFor(socketPath) {
  return {
    enabled: true,
    rootOnly: false,
    sound: false,
    clickAction: "jump-web",
    webUrl: "http://127.0.0.1:3080",
    socketPath,
    // Point the daemon path somewhere harmless: the fake daemon is already up,
    // so no spawn should ever be needed.
    serverPath: "/nonexistent/dsh-notify-server",
  };
}

const session = { id: "session-under-test" };

afterEach(() => {
  for (const { server, socketPath } of sockets.splice(0)) {
    server.close();
    try {
      fs.unlinkSync(socketPath);
    } catch {}
  }
});

// macOS-only by construction: `apply()` deliberately early-returns on other
// platforms ("not on macOS; notifications disabled"), so there are no handlers
// to drive there. The pure-function suite (blocked-resolve.test.js) still runs
// everywhere; CI covers THIS file in the macos job (see .github/workflows).
describe.skipIf(process.platform !== "darwin")("blocked card cleanup over the real socket", () => {
  it("sends show with the ref, then clear with the same ref when the user decides", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, {
      type: "approval/asked",
      data: { id: "ap-1", toolName: "bash", callId: "call_1" },
    });
    const afterAsk = await daemon.waitFor("show");
    const show = afterAsk.find((f) => f.cmd === "show");
    expect(show.kind).toBe("blocked");
    expect(show.ref).toBe("approval:ap-1");
    expect(show.sessionId).toBe("session-under-test");
    expect(show.detail).toBe("等待授权：bash");        // 工具名进 detail
    expect(show.message).toBe("需要你处理，点击查看详情");  // 文案来自配置

    handlers["session/event"](session, {
      type: "approval/decided",
      data: { id: "ap-1", outcome: "allowed-once" },
    });
    const frames = await daemon.waitFor("clear");
    const clear = frames.find((f) => f.cmd === "clear");
    expect(clear).toEqual({
      cmd: "clear",
      sessionId: "session-under-test",
      ref: "approval:ap-1",
    });
  });

  it("clears an ask_user_question row when the tool returns the answer", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, {
      type: "tool/call",
      data: { callId: "call_q", name: "ask_user_question", turn: 2, step: 5 },
    });
    const afterAsk = await daemon.waitFor("show");
    expect(afterAsk.find((f) => f.cmd === "show").ref).toBe("ask:call_q");

    handlers["session/event"](session, {
      type: "tool/result",
      data: { turn: 2, step: 5, message: { source: { kind: "tool", callId: "call_q" }, content: [] } },
    });
    const frames = await daemon.waitFor("clear");
    expect(frames.find((f) => f.cmd === "clear")).toEqual({
      cmd: "clear",
      sessionId: "session-under-test",
      ref: "ask:call_q",
    });
  });

  it("never clears for unrelated tool results (every tool call emits one)", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, {
      type: "tool/result",
      data: { turn: 1, step: 1, message: { source: { kind: "tool", callId: "call_bash" }, content: [] } },
    });
    handlers["session/event"](session, { type: "turn/start", data: { turn: 2 } });
    await new Promise((resolve) => setTimeout(resolve, 80));

    expect(daemon.of("clear")).toHaveLength(0);
  });

  it("clears a single row even if this host never tracked it (approval/decided self-heal)", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    // No preceding approval/asked in this instance (simulates a host restart).
    handlers["session/event"](session, {
      type: "approval/decided",
      data: { id: "ap-lost", outcome: "denied" },
    });
    const frames = await daemon.waitFor("clear");
    expect(frames.find((f) => f.cmd === "clear").ref).toBe("approval:ap-lost");
  });

  it("keeps a pending row when a DIFFERENT approval is decided", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, {
      type: "approval/asked",
      data: { id: "ap-keep", toolName: "bash" },
    });
    await daemon.waitFor("show");
    handlers["session/event"](session, {
      type: "tool/result",
      data: { message: { source: { kind: "tool", callId: "some-other-call" } } },
    });
    await new Promise((resolve) => setTimeout(resolve, 80));

    expect(daemon.of("clear")).toHaveLength(0);
    expect(daemon.of("show")).toHaveLength(1);
  });
});
