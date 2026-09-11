/**
 * Host-side pure-logic regression tests.
 *
 * These pin behaviors that AI review rounds 1-5 flagged and we fixed:
 *   - isRootSession must NOT treat a missing session as root (was:
 *     `undefined?.header?.parentSession === undefined` -> true).
 *   - classifyTurnEndReason must never crash on a non-object reason and must
 *     keep its skip semantics for blocked-cancel ("aborted"+"disposed").
 * Kept deliberately as pure-function tests (no ctx, no sockets, no daemon).
 */
import { describe, expect, it } from "vitest";
import { classifyTurnEndReason, isRootSession, nextTurnState, turnAnchorFor, shouldStartDaemon } from "../lib/index.js";

describe("isRootSession", () => {
  it("returns true for every session when rootOnly is false", () => {
    expect(isRootSession(undefined, false)).toBe(true);
    expect(isRootSession(null, false)).toBe(true);
    expect(isRootSession({ header: { parentSession: { id: 1 } } }, false)).toBe(true);
  });

  it("returns false for a missing session (regression: no card w/o session id)", () => {
    expect(isRootSession(undefined, true)).toBe(false);
    expect(isRootSession(null, true)).toBe(false);
  });

  it("returns true for a session without a parent (top-level conversation)", () => {
    expect(isRootSession({ header: {} }, true)).toBe(true);
    expect(isRootSession({ header: { parentSession: undefined } }, true)).toBe(true);
  });

  it("returns false for a subagent session (has a parentSession)", () => {
    expect(isRootSession({ header: { parentSession: { id: "sub-1" } } }, true)).toBe(false);
  });

  it("never throws on hostile inputs (defaults to false)", () => {
    expect(isRootSession("nope", true)).toBe(false);
    expect(isRootSession(42, true)).toBe(false);
  });
});

describe("classifyTurnEndReason", () => {
  it("skips a missing / non-object reason without crashing", () => {
    expect(classifyTurnEndReason(undefined)).toEqual({ kind: "skip" });
    expect(classifyTurnEndReason(null)).toEqual({ kind: "skip" });
    expect(classifyTurnEndReason("aborted")).toEqual({ kind: "skip" });
    expect(classifyTurnEndReason(7)).toEqual({ kind: "skip" });
  });

  it("skips unknown / benign kinds", () => {
    expect(classifyTurnEndReason({ kind: "complete" })).toEqual({ kind: "skip" });
    expect(classifyTurnEndReason({})).toEqual({ kind: "skip" });
  });

  it("flags error kinds with the error message as detail", () => {
    expect(classifyTurnEndReason({ kind: "error", error: { message: "boom" } })).toEqual({
      kind: "error",
      detail: "boom",
    });
  });

  it("falls back to the kind string when there is no usable error message", () => {
    expect(classifyTurnEndReason({ kind: "max-tokens" })).toEqual({
      kind: "error",
      detail: "max-tokens",
    });
    expect(classifyTurnEndReason({ kind: "error", error: "plain string" })).toEqual({
      kind: "error",
      detail: "error",
    });
  });

  it("skips aborted with sub-reason disposed (blocked cancel already raised blocked)", () => {
    expect(
      classifyTurnEndReason({ kind: "aborted", reason: { kind: "disposed" } })
    ).toEqual({ kind: "skip" });
  });

  it("flags aborted with any OTHER sub-reason as error (current behavior, documented)", () => {
    expect(classifyTurnEndReason({ kind: "aborted", reason: { kind: "cancelled" } })).toEqual({
      kind: "error",
      detail: "aborted",
    });
    expect(classifyTurnEndReason({ kind: "aborted" })).toEqual({
      kind: "error",
      detail: "aborted",
    });
  });

  it("flags interrupted as error too", () => {
    expect(classifyTurnEndReason({ kind: "interrupted" })).toEqual({
      kind: "error",
      detail: "interrupted",
    });
  });
});

describe("turn tracking (#3 position-indexed jump)", () => {
  it("records the open turn on turn/start and the ended turn on turn/end", () => {
    let state = nextTurnState(undefined, { type: "turn/start", data: { turn: 7 } });
    expect(state).toEqual({ open: 7 });

    state = nextTurnState(state, { type: "turn/end", data: { turn: 7, reason: { kind: "completed" } } });
    expect(state).toEqual({ lastEnded: 7 });
  });

  it("keeps a newer open turn while an older one ends", () => {
    let state = nextTurnState(undefined, { type: "turn/start", data: { turn: 9 } });
    state = nextTurnState(state, { type: "turn/start", data: { turn: 10 } });
    state = nextTurnState(state, { type: "turn/end", data: { turn: 9 } });
    expect(state).toEqual({ open: 10, lastEnded: 9 });
  });

  it("ignores events without a numeric turn", () => {
    expect(nextTurnState({ lastEnded: 3 }, { type: "tool/call", data: { callId: "c1" } })).toEqual({ lastEnded: 3 });
    expect(nextTurnState(undefined, { type: "turn/start", data: { turn: "x" } })).toEqual({});
  });

  it("anchors blocked cards on the open turn, others on the ended turn", () => {
    const state = { open: 10, lastEnded: 9 };
    expect(turnAnchorFor(state, "blocked")).toBe(10);
    expect(turnAnchorFor(state, "completed")).toBe(9);
    expect(turnAnchorFor(state, "error")).toBe(9);
    expect(turnAnchorFor({ open: 4 }, "completed")).toBe(4);   // no ended turn yet
    expect(turnAnchorFor(undefined, "completed")).toBeUndefined();
  });
});

describe("daemon respawn policy (regression: killed daemon never respawned)", () => {
  it("spawns when no handle exists", () => {
    expect(shouldStartDaemon({ hasHandle: false, handleDead: false, lastSpawnedAt: 0, now: 1000 })).toBe(true);
  });

  it("spawns when the handle is dead (crash or killed out of band)", () => {
    expect(shouldStartDaemon({ hasHandle: true, handleDead: true, lastSpawnedAt: 1000, now: 1005 })).toBe(true);
  });

  it("throttles respawn attempts for a live handle", () => {
    expect(shouldStartDaemon({ hasHandle: true, handleDead: false, lastSpawnedAt: 1000, now: 1500 })).toBe(false);
    expect(shouldStartDaemon({ hasHandle: true, handleDead: false, lastSpawnedAt: 1000, now: 3001 })).toBe(true);
  });

  it("honours a custom retry window", () => {
    expect(shouldStartDaemon({ hasHandle: true, handleDead: false, lastSpawnedAt: 1000, now: 1100, retryAfterMs: 50 })).toBe(true);
  });
});
