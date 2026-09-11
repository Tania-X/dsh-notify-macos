/**
 * dsh-notify-macos — DSH host plugin.
 *
 * Shows a persistent macOS notification in the top-right corner every time a
 * conversation/turn completes, so the user knows the task is done even when
 * the browser tab is in the background.
 *
 * Signals: listens for the agent-scoped `agent/status` event and detects the
 * `running -> idle` transition. Because an agent stays `running` across all
 * queued turns and only returns to `idle` once the whole batch drains, this
 * fires exactly once per completed conversation round.
 *
 * Rendering: a companion native daemon (`bin/dsh-notify-server`, Swift/AppKit)
 * renders numbered floating cards pinned to the top-right corner of the
 * screen. Each card stays until the user acts:
 *   - drag the card to the right  -> dismiss / clear it
 *   - click the card              -> jump to the completion location (reveal
 *                                    the session's working directory in
 *                                    Finder, or open the Web UI, per config)
 *                                    and dismiss it
 * Multiple tasks finishing at once produce multiple numbered cards.
 *
 * The plugin talks to the daemon over a Unix domain socket
 * (`$TMPDIR/dsh-notify-macos.sock`), auto-starting the daemon on first use.
 * If the daemon cannot be reached, it falls back to a plain `osascript`
 * notification so a task is never silently dropped.
 *
 * @module dsh-notify-macos
 */
import { spawn } from "node:child_process";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import z from "@deepseek-ai/schemastery";

/** Stable Cordis plugin name. */
export const name = "dsh-notify-macos";

/** Services required before the plugin activates. */
export const inject = ["agents", "sessionTitle"];

/** Plugin configuration schema. */
export const Config = z.object({
  /** Master switch; setting false disables all notifications. */
  enabled: z.boolean().default(true),
  /** Fallback title when no session name is available yet. */
  title: z.string().default("DeepSeek Harness"),
  /**
   * Notification bodies per outcome kind. The card's title line always shows
   * the session name; these are the secondary line / detail copy.
   */
  messageCompleted: z.string().default("任务已完成"),
  messageError: z.string().default("任务失败，点击查看详情"),
  messageBlocked: z.string().default("需要你处理，点击查看详情"),
  /** Play the system "Glass" sound with the notification. */
  sound: z.boolean().default(false),
  /**
   * Only notify when a top-level (root) conversation completes. Subagents are
   * still agents with their own `running -> idle` transitions; when false,
   * every subagent completion also raises a notification (can get noisy for
   * workflow runs that fan out many subagents).
   */
  rootOnly: z.boolean().default(true),
  /**
   * What clicking a card does before it is cleared:
   *   - "jump-web":   (default) open the DeepSeek Harness Web UI and jump to
   *                   the finished session's completion point — the browser
   *                   scrolls to the newest message ("task done") in that
   *                   conversation, wherever you were before
   *   - "open-folder": reveal the session's working directory in Finder
   *   - "open-web":   just open the Web UI (no session targeting)
   *   - "none":       just clear the card
   */
  clickAction: z.union([
    z.const("jump-web"),
    z.const("open-folder"),
    z.const("open-web"),
    z.const("none")
  ]).default("jump-web"),
  /** URL opened for `clickAction: "open-web"`. */
  webUrl: z.string().default("http://127.0.0.1:3080"),
  /**
   * Seconds a card stays before auto-dismissing; 0 (default) keeps it until
   * the user drags or clicks it.
   */
  autoDismissSec: z.number().min(0).default(0),
  /** Override for the daemon socket path (defaults to $TMPDIR/dsh-notify-macos.sock). */
  socketPath: z.string(),
  /** Override for the daemon binary path (defaults to ../bin/dsh-notify-server next to this module). */
  serverPath: z.string()
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Default socket path shared with the daemon. */
function defaultSocketPath() {
  return path.join(os.tmpdir(), "dsh-notify-macos.sock");
}

/** Default daemon binary path (sibling of this plugin's package). */
function defaultServerPath() {
  return path.join(__dirname, "..", "bin", "dsh-notify-server");
}

/**
 * Fire a fallback notification via osascript (used when the daemon is down).
 * @param title - notification title.
 * @param message - notification body.
 * @param sound - whether to play the system "Glass" sound.
 */
function osascriptNotify(title, message, sound) {
  const script = `display notification ${JSON.stringify(String(message).replace(/[\n\r\t]/g, " "))} with title ${JSON.stringify(String(title).replace(/[\n\r\t]/g, " "))}${sound ? ' sound name "Glass"' : ""}`;
  const child = spawn("osascript", ["-e", script], { stdio: "ignore" });
  child.on("error", () => {});
  child.unref?.();
}

/**
 * Send one JSON line to the daemon socket; resolves true on success.
 * @param socketPath - daemon socket path.
 * @param payload - object to send.
 * @returns promise resolving to whether the write was accepted.
 */
function sendToDaemon(socketPath, payload) {
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(1200, () => finish(false));
    socket.on("connect", () => {
      socket.write(`${JSON.stringify(payload)}\n`, () => finish(true));
    });
    socket.on("error", () => finish(false));
  });
}

/** Started daemon process handle, if any (kept to avoid duplicate spawns). */
let daemonProcess = null;
/** When the daemon was last spawned (throttles respawn attempts). */
let daemonSpawnedAt = 0;

/**
 * Whether a new daemon should be spawned for this delivery (pure; exported for
 * tests). A daemon that died must be replaced — the old code only spawned when
 * the handle was null, so killing the daemon out of band (or a crash) silently
 * downgraded every later notification to the short-lived system notification.
 *
 * A LIVE handle never triggers a spawn: a failed socket connect does not mean
 * the process is gone (it may still be starting, or the socket file may have
 * been removed). Spawning anyway would race the running daemon — the new
 * instance unlinks and rebinds the same socket path, orphaning the old process.
 * The throttle therefore only limits retries after a missing/dead handle.
 *
 * @param state - `{ hasHandle, handleDead, lastSpawnedAt, now, retryAfterMs }`.
 * @returns true when a spawn should be attempted.
 */
export function shouldStartDaemon({ hasHandle, handleDead, lastSpawnedAt, now, retryAfterMs = 2000 }) {
  if (hasHandle && !handleDead) return false;   // alive → never spawn a rival
  if (typeof lastSpawnedAt !== "number" || lastSpawnedAt <= 0) return true;
  return now - lastSpawnedAt >= retryAfterMs;   // retry window for dead/missing
}

/** Current daemon bookkeeping for shouldStartDaemon. */
function daemonState(now = Date.now()) {
  const handle = daemonProcess;
  const handleDead = handle !== null && (handle.exitCode !== null || handle.killed === true);
  return {
    hasHandle: handle !== null,
    handleDead,
    lastSpawnedAt: daemonSpawnedAt,
    now
  };
}

/**
 * Start the daemon detached so it outlives this process.
 * @param serverPath - daemon binary path.
 * @param socketPath - socket path to hand the daemon.
 */
function startDaemon(serverPath, socketPath) {
  try {
    const child = spawn(serverPath, [socketPath], {
      detached: true,
      stdio: "ignore"
    });
    daemonProcess = child;
    daemonSpawnedAt = Date.now();
    // A dead daemon must not keep blocking future spawns.
    child.on("exit", () => {
      if (daemonProcess === child) daemonProcess = null;
    });
    child.on("error", (error) => {
      console.error("[dsh-notify-macos] daemon spawn error:", error.message);
      if (daemonProcess === child) daemonProcess = null;
    });
    child.unref();
  } catch (error) {
    daemonProcess = null;
    console.error("[dsh-notify-macos] failed to start daemon:", error.message);
  }
}

/**
 * Deliver a notification: try the daemon, start it if missing, and fall back
 * to osascript when the daemon is unavailable.
 * @param cfg - resolved plugin config.
 * @param kind - outcome kind: "completed" | "error" | "blocked".
 * @param message - the message body to show.
 * @param detail - extra structured detail (error message / tool name).
 * @param cwd - the session's working directory (completion location).
 * @param sessionTitle - the session title, when known.
 * @param sessionId - the session id (for browser jump targeting).
 */
async function deliver(cfg, kind, message, detail, cwd, sessionTitle, sessionId, turn) {
  const socketPath = cfg.socketPath ?? defaultSocketPath();
  const serverPath = cfg.serverPath ?? defaultServerPath();
  const payload = {
    cmd: "show",
    title: cfg.title,
    message,
    kind,
    action: cfg.clickAction,
    sound: cfg.sound,
    ...cfg.autoDismissSec > 0 ? { autoDismissSec: cfg.autoDismissSec } : {}
  };
  if (detail !== undefined && detail !== null && detail !== "") payload.detail = String(detail);
  // Position anchor: which turn's completion the click should scroll to.
  if (typeof turn === "number" && Number.isFinite(turn) && turn > 0) payload.turn = turn;
  if (cfg.clickAction === "open-folder") payload.path = cwd ?? "";
  if (cfg.clickAction === "open-web" || cfg.clickAction === "jump-web") payload.url = cfg.webUrl;
  if (cfg.clickAction === "jump-web" && sessionId) payload.sessionId = sessionId;
  if (cfg.clickAction === "jump-web" && sessionTitle) payload.sessionTitle = sessionTitle;

  let ok = await sendToDaemon(socketPath, payload);
  if (!ok && shouldStartDaemon(daemonState())) {
    // First use (or daemon died): start it and retry once.
    startDaemon(serverPath, socketPath);
    await new Promise((resolve) => setTimeout(resolve, 400));
    ok = await sendToDaemon(socketPath, payload);
  }
  if (!ok) {
    // osascript fallback: title = session name when known, else configured title.
    osascriptNotify(sessionTitle || cfg.title, message, cfg.sound);
  }
}

/**
 * Read the current session title snapshot, or undefined.
 * @param ctx - plugin context (provides `sessionTitle`).
 * @param agent - the agent whose session title to read.
 */
function sessionTitleOf(ctx, agent) {
  try {
    return ctx.sessionTitle.get(agent.session)?.title;
  } catch {
    return undefined;
  }
}

/**
 * Resolve the underlying Session from either an agent (has `.session`) or a
 * bare session object (e.g. from a `session/event` callback).
 */
function sessionOf(input) {
  if (input === null || typeof input !== "object") return undefined;
  return input.session !== undefined ? input.session : input;
}

/** Read the session's working directory, or undefined. Accepts agent or session. */
function cwdOf(input) {
  try {
    const session = sessionOf(input);
    const cwd = session?.header?.cwd;
    return typeof cwd === "string" && cwd.length > 0 ? cwd : undefined;
  } catch {
    return undefined;
  }
}

/** Read the session id, or undefined. Accepts agent or session. */
function sessionIdOf(input) {
  try {
    const session = sessionOf(input);
    const id = session?.id ?? input?.id;
    return typeof id === "string" && id.length > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Decide whether a session is a top-level conversation (not a subagent).
 * Pure: no ctx/config access — extracted for unit testing.
 * @param session - the session object (agent.session or a bare session).
 * @param rootOnly - config.rootOnly; when false every session qualifies.
 * @returns true when the session should raise notifications.
 */
export function isRootSession(session, rootOnly = true) {
  if (!rootOnly) return true;
  // A missing or non-object session must never be treated as a root:
  // optional chaining alone would turn `undefined?.x === undefined` into
  // true (and property access on a string boxes it to an object), raising a
  // card with no session id (nothing to jump to).
  if (session === null || typeof session !== "object") return false;
  try {
    return session.header?.parentSession === undefined;
  } catch {
    return false;
  }
}

/**
 * Classify a session/event "turn/end" payload into an outcome.
 * Pure: extracted for unit testing. Mirrors the rules that historically
 * lived inline in the turn/end handler:
 *   - non-object reason            -> skip (schema guard, never crash)
 *   - kind not in the bad list     -> skip
 *   - aborted whose sub-reason is
 *     "disposed" (blocked cancel)  -> skip (blocked was raised earlier)
 *   - anything else bad            -> { kind: "error", detail }
 * @param reason - `event.data?.reason` from a turn/end event.
 * @returns `{ kind: "error", detail }` or `{ kind: "skip" }`.
 */
export function classifyTurnEndReason(reason) {
  if (reason === null || typeof reason !== "object") return { kind: "skip" };
  const kind = typeof reason.kind === "string" ? reason.kind : "";
  const bad = ["error", "aborted", "interrupted", "max-tokens"];
  if (!bad.includes(kind)) return { kind: "skip" };
  const subReason = reason.reason;
  const subKind =
    subReason !== null && typeof subReason === "object" && typeof subReason.kind === "string"
      ? subReason.kind
      : "";
  if (kind === "aborted" && subKind === "disposed") return { kind: "skip" };
  const err = reason.error;
  const detail =
    err !== null && typeof err === "object" && typeof err.message === "string"
      ? err.message
      : kind;
  return { kind: "error", detail };
}

/**
 * Pure turn-tracking state transition for one session/event.
 * The session log carries `data.turn` on turn/start, turn/end and tool events;
 * tracking it lets a card remember WHICH turn it came from, so a click can
 * scroll to that turn's completion instead of the session bottom.
 * @param state - previous `{ open, lastEnded }` state (or undefined).
 * @param event - a `session/event` payload.
 * @returns the next state.
 */
export function nextTurnState(state, event) {
  const next = { ...(state ?? {}) };
  const turn = event?.data?.turn;
  if (typeof turn !== "number") return next;
  if (event.type === "turn/start") {
    next.open = turn;
  } else if (event.type === "turn/end") {
    next.lastEnded = turn;
    if (next.open === turn) delete next.open;
  }
  return next;
}

/**
 * Which turn a card of `kind` should anchor to.
 * blocked → the turn currently waiting on the user; otherwise the turn that
 * just ended (falling back to the open one).
 * @param state - `{ open, lastEnded }` for the session.
 * @param kind - outcome kind.
 * @returns a turn number, or undefined when unknown.
 */
export function turnAnchorFor(state, kind) {
  const s = state ?? {};
  if (kind === "blocked") return s.open ?? s.lastEnded;
  return s.lastEnded ?? s.open;
}

/**
 * Install the plugin. Outcome kinds:
 *   - completed: agent/status running -> idle (a turn finished cleanly).
 *   - error:     session/event turn/end with reason kind error/aborted/
 *                interrupted/max-tokens — the run ended badly.
 *   - blocked:   session/event approval/asked (waiting for approval) or
 *                tool/call of ask_user_question (waiting for an answer) —
 *                the run is paused until the user acts.
 * Each kind raises its own card so the user sees at a glance whether the
 * session finished, failed, or needs attention.
 * @param ctx - plugin context.
 * @param config - validated plugin configuration.
 */
export function apply(ctx, config = {}) {
  if (process.platform !== "darwin") {
    ctx.logger.warn("[dsh-notify-macos] not on macOS; notifications disabled");
    return;
  }
  // Defense-in-depth defaults (the Config schema normally provides these).
  const enabled = config.enabled ?? true;
  const sound = config.sound ?? false;
  const rootOnly = config.rootOnly ?? true;
  const copy = {
    completed: config.messageCompleted ?? "任务已完成",
    error: config.messageError ?? "任务失败，点击查看详情",
    blocked: config.messageBlocked ?? "需要你处理，点击查看详情"
  };

  /** Per-session turn tracking (see nextTurnState/turnAnchorFor). */
  const turns = new WeakMap();

  /** Raise a card for one outcome on a session. */
  const notify = (session, kind, detail) => {
    if (!enabled || !isRootSession(session, rootOnly)) return;
    let title;
    try {
      title = ctx.sessionTitle.get(session)?.title;
    } catch {
      title = undefined;
    }
    const turn = turnAnchorFor(turns.get(session), kind);
    void deliver(
      config, kind, copy[kind] ?? "任务已完成", detail,
      cwdOf({ session }), title, sessionIdOf({ session }), turn
    );
  };

  // --- completed: running -> idle -------------------------------------------
  const previous = new WeakMap();
  ctx.on("agent/status", ({ agent, status }) => {
    const before = previous.get(agent);
    previous.set(agent, status);
    if (before !== "running" || status !== "idle") return;
    if (!enabled || !isRootSession(agent.session, rootOnly)) return;
    const sessionTitle = sessionTitleOf(ctx, agent);
    const turn = turnAnchorFor(turns.get(agent.session), "completed");
    void deliver(
      config, "completed", copy.completed, undefined,
      cwdOf(agent), sessionTitle, sessionIdOf(agent), turn
    );
  });

  // --- error / blocked: session events --------------------------------------
  ctx.on("session/event", (session, event) => {
    if (!enabled || !isRootSession(session, rootOnly)) return;
    // Track turn boundaries for every event, whatever the outcome below.
    turns.set(session, nextTurnState(turns.get(session), event));
    switch (event.type) {
      case "turn/end": {
        const reason = event.data?.reason;
        const verdict = classifyTurnEndReason(reason);
        if (verdict.kind === "error") notify(session, "error", verdict.detail);
        break;
      }
      case "turn/start":
        break;   // state already tracked above
      case "approval/asked": {
        const tool = event.data?.toolName ?? "";
        notify(session, "blocked", tool ? `等待授权：${tool}` : "等待授权");
        break;
      }
      case "tool/call": {
        if (event.data?.name === "ask_user_question") {
          notify(session, "blocked", "等待你的回答");
        }
        break;
      }
      default:
        break;
    }
  });

  // Pre-warm the daemon so the first completion notification is not delayed
  // by a cold spawn (a failed spawn is harmless; delivery falls back later).
  const socketPath = config.socketPath ?? defaultSocketPath();
  const serverPath = config.serverPath ?? defaultServerPath();
  void sendToDaemon(socketPath, { cmd: "ping" }).then((ok) => {
    if (!ok && shouldStartDaemon(daemonState())) startDaemon(serverPath, socketPath);
  });
}
