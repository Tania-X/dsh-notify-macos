/**
 * 「失败的一轮不要再补一张绿卡」——回归测试（真 socket + 假 daemon）。
 *
 * 用户实测反馈：任务失败时先出红卡，随后又冒出一张绿色的"任务已完成"。
 * 根因：完成卡的触发信号是 `agent/status` 的 `running → idle`，它只知道"这一批 turn
 * 排空了"，并不知道这批是成功还是失败；而失败卡来自另一个信号（`turn/end` 的 reason）。
 * 两个信号各自成立，于是同一轮既红又绿。
 *
 * 这里的断言就是"再坏一次会怎样"：把抑制逻辑去掉，第 2 条用例立刻变红。
 * 骨架与 blocked-resolve-integration.test.js 相同（假 daemon 跑真 socket，驱动真实
 * 的 apply()），只是这份自成一体、只带需要的东西。
 */
import { afterEach, describe, expect, it } from "vitest";
import net from "node:net";
import fs from "node:fs";
import { apply } from "../lib/index.js";

const sockets = [];

/** 在私有 unix socket 上假扮 daemon，并收集它收到的帧。 */
async function fakeDaemon() {
  // 路径要短：unix socket 地址有 ~104 字节上限，而 macOS 的 os.tmpdir() 会超。
  const socketPath = `/tmp/dsh-notify-err-${process.pid}-${sockets.length}.sock`;
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
    of: (cmd) => frames.filter((f) => f.cmd === cmd),
    /** 等到 `cmd` 累计出现 count 次（apply() 会先 ping 预热，所以不能只等"有帧了"）。 */
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
    /** 给"应该什么都不发生"的断言一点时间：等一小会儿再看。 */
    async settle(ms = 250) {
      await new Promise((resolve) => setTimeout(resolve, ms));
      return frames;
    }
  };
}

function fakeCtx() {
  const handlers = {};
  return {
    handlers,
    ctx: {
      on(name, fn) {
        handlers[name] = fn;
      },
      sessionTitle: { get: () => ({ title: "Test Session" }) },
      logger: { warn: () => {}, info: () => {}, debug: () => {} }
    }
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
    serverPath: "/nonexistent/dsh-notify-server"
  };
}

const session = { id: "session-error-test" };
const agent = { session };

afterEach(() => {
  for (const { server, socketPath } of sockets.splice(0)) {
    server.close();
    try {
      fs.unlinkSync(socketPath);
    } catch {}
  }
});

// macOS-only：apply() 在非 macOS 会直接早退（"not on macOS; notifications disabled"），
// 那边没有 handler 可驱动。CI 的 macos job 覆盖本文件。
describe.skipIf(process.platform !== "darwin")("失败的一轮不该再补绿卡", () => {
  it("失败的一轮：只发红卡，agent 回到 idle 时不再补 'completed'", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, { type: "turn/start", data: { turn: 3 } });
    handlers["session/event"](session, {
      type: "turn/end",
      data: { turn: 3, reason: { kind: "error", error: { message: "boom" } } }
    });
    await daemon.waitFor("show", 1);

    // agent 排空 → 回到 idle：**这正是原来补出绿卡的地方**
    handlers["agent/status"]({ agent, status: "running" });
    handlers["agent/status"]({ agent, status: "idle" });
    const frames = await daemon.settle();

    const shows = frames.filter((f) => f.cmd === "show");
    expect(shows.map((f) => f.kind)).toEqual(["error"]);
    expect(shows[0].detail).toBe("boom");
  });

  it("干净的一轮：照样发完成卡（别把正常路径一起掐了）", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, { type: "turn/start", data: { turn: 4 } });
    handlers["session/event"](session, { type: "turn/end", data: { turn: 4 } });
    handlers["agent/status"]({ agent, status: "running" });
    handlers["agent/status"]({ agent, status: "idle" });
    const frames = await daemon.waitFor("show", 1);

    const shows = frames.filter((f) => f.cmd === "show");
    expect(shows.map((f) => f.kind)).toEqual(["completed"]);
    expect(shows[0].turn).toBe(4);   // 锚点仍指向刚结束的那一轮
  });

  it("同一批里失败之后还有下一个 turn：仍然只发红卡（评审指出的路径）", async () => {
    // 这批的关键：turn 3 失败后 turn 4 立刻 turn/start，而 agent 全程保持 running
    // （从未回到 idle）。若在 turn/start 处清标记，整批排空时就会又补一张绿卡。
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    handlers["session/event"](session, { type: "turn/start", data: { turn: 3 } });
    handlers["session/event"](session, {
      type: "turn/end",
      data: { turn: 3, reason: { kind: "error", error: { message: "boom" } } }
    });
    handlers["session/event"](session, { type: "turn/start", data: { turn: 4 } });
    handlers["session/event"](session, { type: "turn/end", data: { turn: 4 } });
    handlers["agent/status"]({ agent, status: "running" });
    handlers["agent/status"]({ agent, status: "idle" });
    await daemon.waitFor("show", 1);
    const frames = await daemon.settle();

    expect(frames.filter((f) => f.cmd === "show").map((f) => f.kind)).toEqual(["error"]);
  });

  it("失败之后的下一轮成功：绿卡要回来（旧的失败结局必须及时作废）", async () => {
    const daemon = await fakeDaemon();
    const { ctx, handlers } = fakeCtx();
    apply(ctx, configFor(daemon.socketPath));

    // 第 1 轮：失败
    handlers["session/event"](session, { type: "turn/start", data: { turn: 5 } });
    handlers["session/event"](session, {
      type: "turn/end",
      data: { turn: 5, reason: { kind: "error", error: { message: "boom" } } }
    });
    handlers["agent/status"]({ agent, status: "running" });
    handlers["agent/status"]({ agent, status: "idle" });
    await daemon.waitFor("show", 1);

    // 第 2 轮：成功（turn/start 应当把上一轮的失败结局清掉）
    handlers["session/event"](session, { type: "turn/start", data: { turn: 6 } });
    handlers["session/event"](session, { type: "turn/end", data: { turn: 6 } });
    handlers["agent/status"]({ agent, status: "running" });
    handlers["agent/status"]({ agent, status: "idle" });
    await daemon.waitFor("show", 2);
    const frames = await daemon.settle();   // 再多等一会儿：总数必须是 2，多一张就是又补了绿卡

    const kinds = frames.filter((f) => f.cmd === "show").map((f) => f.kind);
    expect(kinds).toEqual(["error", "completed"]);
  });
});
