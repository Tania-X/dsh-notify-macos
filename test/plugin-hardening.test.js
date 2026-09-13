/**
 * 防御式加载的回归测试：**插件加载失败绝不能拖垮 harness**。
 *
 * 动机（DSH 升级场景）：升级后契约可能变（ctx.on 签名、事件载荷、前端服务……）。
 * 那时我们允许的行为是"安静降级 —— 卡片不弹"，绝不允许"抛错影响 DSH 启动/事件总线"。
 */
import { describe, expect, it } from "vitest";
import { apply } from "../lib/index.js";

/** 收集日志的假 ctx。 */
function makeCtx({ on = () => {}, logger = true } = {}) {
  const handlers = {};
  const logs = [];
  const ctx = {
    sessionTitle: { get: () => ({ title: "T" }) },
    logger: logger
      ? {
          warn: (...a) => logs.push(a.join(" ")),
          info: (...a) => logs.push(a.join(" ")),
          debug: () => {}
        }
      : undefined,
    on: (name, fn) => {
      const result = on(name, fn);
      if (typeof fn === "function") handlers[name] = fn;
      return result;
    },
    get: () => undefined
  };
  return { ctx, handlers, logs };
}

const config = {
  enabled: true,
  rootOnly: false,
  sound: false,
  clickAction: "jump-web",
  webUrl: "http://127.0.0.1:3080",
  socketPath: "/tmp/dsh-notify-hardening-test.sock",
  serverPath: "/nonexistent/dsh-notify-server"
};

describe.skipIf(process.platform !== "darwin")("defensive plugin loading", () => {
  it("does not throw when ctx lacks `on` (contract drift) and says so", () => {
    const { ctx, logs } = makeCtx();
    delete ctx.on;
    expect(() => apply(ctx, config)).not.toThrow();
    expect(logs.join("\n")).toContain("ctx.on 不可用");
  });

  it("does not throw when registering handlers fails, and logs the degradation", () => {
    const boom = makeCtx({
      on: () => {
        throw new Error("boom: ctx.on signature changed");
      }
    });
    expect(() => apply(boom.ctx, config)).not.toThrow();
    expect(boom.logs.join("\n")).toContain("插件加载失败");
  });

  it("survives a broken logger (logging failure must not become a crash)", () => {
    const { ctx } = makeCtx();
    ctx.logger = {
      warn: () => {
        throw new Error("logger exploded");
      }
    };
    delete ctx.on;
    expect(() => apply(ctx, config)).not.toThrow();
  });

  it("swallows a malformed session event instead of throwing into the bus", () => {
    const { ctx, handlers, logs } = makeCtx();
    apply(ctx, config);
    expect(typeof handlers["session/event"]).toBe("function");
    // 升级后事件形状变化时最可能的形态：不是对象、缺 data、type 缺失
    expect(() => handlers["session/event"]({ id: "s1" }, undefined)).not.toThrow();
    expect(() => handlers["session/event"]({ id: "s1" }, {})).not.toThrow();
    expect(() => handlers["session/event"](undefined, { type: "turn/end" })).not.toThrow();
    expect(logs.join("\n")).toContain("session/event handler 出错");
  });

  it("swallows a malformed agent status payload", () => {
    const { ctx, handlers } = makeCtx();
    apply(ctx, config);
    expect(() => handlers["agent/status"]({})).not.toThrow();
    expect(() => handlers["agent/status"](undefined)).not.toThrow();
  });

  it("keeps working for a well-formed event (no regression from the guards)", () => {
    const { ctx, handlers, logs } = makeCtx();
    apply(ctx, config);
    handlers["session/event"]({ id: "s1" }, { type: "turn/start", data: { turn: 7 } });
    expect(logs.join("\n")).not.toContain("handler 出错");
  });
});
