/**
 * 「琥珀色卡片在你处理完之后自动消失」的 host 侧纯逻辑测试。
 *
 * 取证（真实会话日志）：
 *   approval/asked   -> {id, toolName, callId, reason}
 *   approval/decided -> {id, outcome}            ← 同一个 id 关联
 *   tool/call(ask_user_question) -> {callId, name}
 *   tool/result      -> message.source.callId    ← 问句被回答
 *
 * 因此实现不是"按 kind 猜"，而是给每一行一个精确的关联键 ref
 * （approval:<id> / ask:<callId>），由 host 判定"已处理"后下发 clear。
 */
import { describe, expect, it } from "vitest";
import {
  blockedRef,
  buildShowPayload,
  nextPendingRefs,
  resolvedRef,
  shouldClearResolved,
} from "../lib/index.js";

const asked = (id = "a1") => ({
  type: "approval/asked",
  data: { id, toolName: "bash", callId: "call_1", reason: "escalate" },
});
const decided = (id = "a1") => ({ type: "approval/decided", data: { id, outcome: "allowed-once" } });
const ask = (callId = "call_q") => ({
  type: "tool/call",
  data: { callId, name: "ask_user_question", arguments: "{}", turn: 2, step: 5 },
});
const answer = (callId = "call_q") => ({
  type: "tool/result",
  data: { turn: 2, step: 5, message: { source: { kind: "tool", callId }, content: [] } },
});

describe("blockedRef", () => {
  it("maps an approval ask to approval:<id>", () => {
    expect(blockedRef(asked("x9"))).toBe("approval:x9");
  });

  it("maps an ask_user_question call to ask:<callId>", () => {
    expect(blockedRef(ask("c7"))).toBe("ask:c7");
  });

  it("yields no key when an approval carries no id", () => {
    // approval/decided only has `id`, so a callId-derived key could never match:
    // emit nothing rather than a dangling key (the row keeps the old
    // click-to-dismiss behaviour).
    expect(blockedRef({ type: "approval/asked", data: { callId: "c1", toolName: "bash" } })).toBeNull();
    expect(blockedRef({ type: "approval/asked", data: { toolName: "bash" } })).toBeNull();
  });

  it("ignores events that do not await the user", () => {
    expect(blockedRef({ type: "turn/end", data: {} })).toBeNull();
    expect(blockedRef({ type: "tool/call", data: { callId: "c", name: "bash" } })).toBeNull();
    expect(blockedRef({ type: "approval/asked", data: {} })).toBeNull();
    expect(blockedRef(null)).toBeNull();
    expect(blockedRef(undefined)).toBeNull();
  });
});

describe("resolvedRef", () => {
  it("maps approval/decided to the SAME key the ask produced", () => {
    // 关键不变式：产生琥珀行的键 == 解决它的键，否则 daemon 删不到那一行。
    expect(resolvedRef(decided("same"))).toBe(blockedRef(asked("same")));
    expect(resolvedRef(asked("same"))).toBeNull();   // 请求本身不是"已处理"
  });

  it("maps the ask tool's result to the SAME key the question produced", () => {
    expect(resolvedRef(answer("c3"))).toBe(blockedRef(ask("c3")));
    expect(resolvedRef(ask("c3"))).toBeNull();
  });

  it("reads the callId from tool-result content too", () => {
    expect(
      resolvedRef({
        type: "tool/result",
        data: { message: { content: [{ type: "tool-result", toolCallId: "fromContent" }] } },
      }),
    ).toBe("ask:fromContent");
  });

  it("ignores unrelated events (every tool call produces a tool/result)", () => {
    expect(resolvedRef({ type: "tool/result", data: { message: { source: {} } } })).toBeNull();
    expect(resolvedRef({ type: "turn/start", data: {} })).toBeNull();
    expect(resolvedRef(null)).toBeNull();
  });
});

describe("shouldClearResolved", () => {
  it("clears when this host raised the row", () => {
    expect(shouldClearResolved("ask:c3", true, answer("c3"))).toBe(true);
  });

  it("clears an untracked approval/decided (self-heal after a host restart)", () => {
    expect(shouldClearResolved("approval:a1", false, decided("a1"))).toBe(true);
  });

  it("does not fire for untracked tool/result noise", () => {
    expect(shouldClearResolved("ask:c3", false, answer("c3"))).toBe(false);
  });

  it("never fires without a key", () => {
    expect(shouldClearResolved(null, true, decided())).toBe(false);
  });
});

describe("nextPendingRefs", () => {
  it("tracks a raised approval and reports it cleared on decided", () => {
    const first = nextPendingRefs(undefined, asked("p1"));
    expect(first.raised).toBe("approval:p1");
    expect([...first.pending]).toEqual(["approval:p1"]);

    const second = nextPendingRefs({ pending: [...first.pending] }, decided("p1"));
    expect(second.resolved).toBe("approval:p1");
    expect(second.wasPending).toBe(true);
    expect([...second.pending]).toEqual([]);
  });

  it("tracks an ask and reports it cleared by the tool result", () => {
    const first = nextPendingRefs(undefined, ask("q1"));
    const second = nextPendingRefs({ pending: [...first.pending] }, answer("q1"));
    expect(second.wasPending).toBe(true);
    expect([...second.pending]).toEqual([]);
  });

  it("keeps unrelated pending entries and ignores unrelated events", () => {
    const s1 = nextPendingRefs(undefined, asked("keep"));
    const s2 = nextPendingRefs({ pending: [...s1.pending] }, { type: "turn/start", data: {} });
    expect([...s2.pending]).toEqual(["approval:keep"]);
    expect(s2.resolved).toBeNull();

    const s3 = nextPendingRefs({ pending: [...s2.pending] }, answer("other"));
    expect([...s3.pending]).toEqual(["approval:keep"]);
    expect(s3.wasPending).toBe(false);   // 不是我们登记的那一条
  });

  it("handles an empty/garbage previous state", () => {
    expect([...nextPendingRefs(null, { type: "turn/end", data: {} }).pending]).toEqual([]);
    expect([...nextPendingRefs({ pending: "nope" }, { type: "turn/end", data: {} }).pending]).toEqual([]);
  });
});

describe("buildShowPayload", () => {
  const cfg = { title: "T", clickAction: "jump-web", sound: false, webUrl: "http://127.0.0.1:3080" };

  it("carries the blocked correlation key so the daemon can drop that row", () => {
    const p = buildShowPayload(
      cfg, "blocked", "等待授权：bash", "bash", "/tmp", "S", "sess-1", 7, "approval:a1",
    );
    expect(p.ref).toBe("approval:a1");
    expect(p.turn).toBe(7);
    expect(p.sessionId).toBe("sess-1");
    expect(p.kind).toBe("blocked");
  });

  it("omits ref/turn when they are unknown (no empty fields on the wire)", () => {
    const p = buildShowPayload(cfg, "completed", "done", undefined, "/tmp", "S", "sess-1", undefined, null);
    expect("ref" in p).toBe(false);
    expect("turn" in p).toBe(false);
    expect("detail" in p).toBe(false);
  });

  it("drops a non-positive turn but keeps a valid ref", () => {
    const p = buildShowPayload(cfg, "blocked", "m", "", "/tmp", "S", "sess-1", 0, "ask:c9");
    expect("turn" in p).toBe(false);
    expect(p.ref).toBe("ask:c9");
  });
});
