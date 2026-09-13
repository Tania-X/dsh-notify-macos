import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * 跳转后的滚动校正（client 半区的 UX 关键路径）。
 *
 * 为什么值得单独测：这段代码要在"页面还在分页加载历史"的前提下把视口带到目标位置，
 * 所以必须连续几轮校正滚动位置 —— 但**用户一旦自己滚动，继续校正就变成和用户抢滚动条**。
 * 实测症状：跳转完成后最长 6~8 秒内，手动上下滚会被一次次拽回跳转位置。
 *
 * 这里用假 DOM 装出真实场景（滚动容器会被写 scrollTop、内容还在长、用户中途滚动），
 * 断言两件事：①**没到位时确实还在校正**（否则"停手"的断言会因为没有在动而假通过）；
 * ②**用户一接管就再也不写 scrollTop**。
 */
const CLIENT_SOURCE = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "lib",
  "client.js"
);

/** 造一个假页面并加载 lib/client.js（与 web shell 的加载方式一致）。 */
function loadClient({ clientHeight = 500, rows = [], growOnScroll = 0 } = {}) {
  const writes = [];
  let scrollHeight = 2000;
  const scroller = {
    clientHeight,
    get scrollHeight() {
      return scrollHeight;
    },
    _top: 0,
    get scrollTop() {
      return this._top;
    },
    set scrollTop(value) {
      // 像浏览器那样钳到可滚动范围内 —— 不钳的话"是否到底"的判定会失真，
      // 断言就会基于一个真实页面里不存在的状态（我第一版假件就踩了这个）。
      const max = Math.max(0, scrollHeight - clientHeight);
      this._top = Math.min(Math.max(value, 0), max);
      writes.push(this._top);
      // 模拟"历史还在分页加载"：每次校正后内容又长高，于是下次仍不在底部
      scrollHeight += growOnScroll;
    },
    getBoundingClientRect: () => ({ top: 0 }),
    querySelectorAll: (selector) => (selector === "[data-chat-anchor-key]" ? rows : []),
    querySelector: () => null
  };

  const win = new EventTarget();
  win.location = { hash: "", href: "http://127.0.0.1:3081/" };
  win.history = { replaceState: () => {} };
  let captured;
  win.__ModuleLoader__ = {
    load: (spec) => {
      captured = spec;
    }
  };

  globalThis.window = win;
  globalThis.document = {
    querySelector: (selector) =>
      selector === "[data-conversation-scroll]" ? scroller : null
  };

  vm.runInThisContext(fs.readFileSync(CLIENT_SOURCE, "utf8"), {
    filename: CLIENT_SOURCE
  });
  const mod = captured.factory(() => ({}));

  const opened = [];
  mod.apply({
    get: (service) => (service === "sessions" ? { open: (id) => opened.push(id) } : undefined)
  });

  const jump = (sessionId, turn) => {
    win.location.hash = `#dsh-notify-macos/session=${sessionId}${turn === undefined ? "" : `&turn=${turn}`}`;
    win.dispatchEvent(new Event("hashchange"));
  };
  const userInput = (type, key) => {
    const event = new Event(type);
    if (key !== undefined) event.key = key;
    win.dispatchEvent(event);
  };
  return { win, scroller, writes, opened, jump, userInput };
}

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
  delete globalThis.window;
  delete globalThis.document;
});

describe("跳转后的滚动校正", () => {
  it("没有锚点时钉到最新，并在到底后立即收工", () => {
    const { scroller, writes, opened, jump } = loadClient();
    jump("session-a");

    vi.advanceTimersByTime(300);
    expect(opened).toEqual(["session-a"]);
    expect(scroller.scrollTop).toBe(1500); // 2000 - 500 = 底部

    const settled = writes.length;
    vi.advanceTimersByTime(10000); // 远超 6 秒上限
    expect(writes.length).toBe(settled); // 到位就停，不再周期性写
  });

  it("还没到位时确实在持续校正（否则「停手」断言会假通过）", () => {
    const { writes, jump } = loadClient({ growOnScroll: 200 });
    jump("session-b");

    vi.advanceTimersByTime(600);
    const early = writes.length;
    vi.advanceTimersByTime(600);
    expect(writes.length).toBeGreaterThan(early); // 内容在长 → 仍在跟着底部校正
  });

  it("用户一滚动（wheel）就立刻停手，之后不再被拽回", () => {
    const { writes, jump, userInput } = loadClient({ growOnScroll: 200 });
    jump("session-c");
    vi.advanceTimersByTime(600);
    expect(writes.length).toBeGreaterThan(1); // 校正中（相当于"锁定"窗口内）

    userInput("wheel");
    const afterTakeover = writes.length;
    vi.advanceTimersByTime(10000);
    expect(writes.length).toBe(afterTakeover); // 一个字节的 scrollTop 都不再写
  });

  it("方向键同样算接管，普通字母键不算", () => {
    const keyboard = loadClient({ growOnScroll: 200 });
    keyboard.jump("session-d");
    vi.advanceTimersByTime(600);
    keyboard.userInput("keydown", "a"); // 普通字符：不该打断
    const beforeArrow = keyboard.writes.length;
    vi.advanceTimersByTime(400);
    expect(keyboard.writes.length).toBeGreaterThan(beforeArrow);

    keyboard.userInput("keydown", "PageUp"); // 翻页键：算接管
    const afterArrow = keyboard.writes.length;
    vi.advanceTimersByTime(10000);
    expect(keyboard.writes.length).toBe(afterArrow);
  });

  it("触摸滚动也算接管（触控板/移动端）", () => {
    const { writes, jump, userInput } = loadClient({ growOnScroll: 200 });
    jump("session-e");
    vi.advanceTimersByTime(400);
    userInput("touchmove");
    const after = writes.length;
    vi.advanceTimersByTime(10000);
    expect(writes.length).toBe(after);
  });

  it("行已经在目标位置时一个 scrollTop 都不写（到位就别再动它）", () => {
    const row = {
      dataset: { chatAnchorKey: "row:turn-tail7" },
      getBoundingClientRect: () => ({ top: 300 }) // clientHeight*0.6 = 300 → 已对齐
    };
    const { writes, scroller, jump } = loadClient({ rows: [row] });
    jump("session-f", 7);

    vi.advanceTimersByTime(1000);
    expect(scroller.scrollTop).toBe(0);
    expect(writes.length).toBe(0);
  });

  it("行还没对齐时用户滚动，也必须立刻停手", () => {
    // 行永远对不齐（模拟"历史还在往上分页、行一直在动"）：这时循环会一直校正，
    // 正是用户抱怨的场景。
    const row = {
      dataset: { chatAnchorKey: "row:turn-tail7" },
      getBoundingClientRect: () => ({ top: 400 })
    };
    const { writes, jump, userInput } = loadClient({ rows: [row] });
    jump("session-f", 7);

    vi.advanceTimersByTime(400);
    expect(writes.length).toBeGreaterThan(1); // 确实在持续校正

    userInput("wheel");
    const after = writes.length;
    vi.advanceTimersByTime(10000);
    expect(writes.length).toBe(after);
  });
});
