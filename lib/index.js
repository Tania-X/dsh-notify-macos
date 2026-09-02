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
  /** Notification title (also used as the card's title line). */
  title: z.string().default("DeepSeek Harness"),
  /** Notification body; `{title}` is replaced with the session title when known. */
  message: z.string().default("任务已完成"),
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

/**
 * Start the daemon detached so it outlives this process.
 * @param serverPath - daemon binary path.
 * @param socketPath - socket path to hand the daemon.
 */
function startDaemon(serverPath, socketPath) {
  try {
    daemonProcess = spawn(serverPath, [socketPath], {
      detached: true,
      stdio: "ignore"
    });
    daemonProcess.unref();
  } catch (error) {
    console.error("[dsh-notify-macos] failed to start daemon:", error.message);
  }
}

/**
 * Deliver a notification: try the daemon, start it if missing, and fall back
 * to osascript when the daemon is unavailable.
 * @param cfg - resolved plugin config.
 * @param message - the message body to show.
 * @param cwd - the session's working directory (completion location).
 * @param sessionTitle - the session title, when known.
 * @param sessionId - the session id (for browser jump targeting).
 */
async function deliver(cfg, message, cwd, sessionTitle, sessionId) {
  const socketPath = cfg.socketPath ?? defaultSocketPath();
  const serverPath = cfg.serverPath ?? defaultServerPath();
  const payload = {
    cmd: "show",
    title: cfg.title,
    message,
    action: cfg.clickAction,
    sound: cfg.sound,
    ...cfg.autoDismissSec > 0 ? { autoDismissSec: cfg.autoDismissSec } : {}
  };
  if (cfg.clickAction === "open-folder") payload.path = cwd ?? "";
  if (cfg.clickAction === "open-web" || cfg.clickAction === "jump-web") payload.url = cfg.webUrl;
  if (cfg.clickAction === "jump-web" && sessionId) payload.sessionId = sessionId;
  if (cfg.clickAction === "jump-web" && sessionTitle) payload.sessionTitle = sessionTitle;

  let ok = await sendToDaemon(socketPath, payload);
  if (!ok && daemonProcess === null) {
    // First use (or daemon died): start it and retry once.
    startDaemon(serverPath, socketPath);
    await new Promise((resolve) => setTimeout(resolve, 400));
    ok = await sendToDaemon(socketPath, payload);
  }
  if (!ok) {
    osascriptNotify(cfg.title, sessionTitle ? message : message, cfg.sound);
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

/** Read the session's working directory, or undefined. */
function cwdOf(agent) {
  try {
    const cwd = agent.session?.header?.cwd;
    return typeof cwd === "string" && cwd.length > 0 ? cwd : undefined;
  } catch {
    return undefined;
  }
}

/** Read the session id, or undefined. */
function sessionIdOf(agent) {
  try {
    const id = agent.session?.id ?? agent.id;
    return typeof id === "string" && id.length > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Install the plugin: track per-agent status, notify on `running -> idle`.
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
  const title = config.title ?? "DeepSeek Harness";
  const message = config.message ?? "任务已完成";
  const sound = config.sound ?? false;
  const rootOnly = config.rootOnly ?? true;

  /** Previous observed status per agent (WeakMap keeps no leaks on disposal). */
  const previous = new WeakMap();
  ctx.on("agent/status", ({ agent, status }) => {
    const before = previous.get(agent);
    previous.set(agent, status);
    if (before !== "running" || status !== "idle") return;
    if (!enabled) return;
    if (rootOnly) {
      let isRoot = false;
      try {
        isRoot = ctx.agents.roots().includes(agent);
      } catch {
        isRoot = false;
      }
      if (!isRoot) return;
    }
    const sessionTitle = sessionTitleOf(ctx, agent);
    const body = sessionTitle
      ? message.replaceAll("{title}", sessionTitle)
      : message;
    void deliver(config, body, cwdOf(agent), sessionTitle, sessionIdOf(agent));
  });

  // Pre-warm the daemon so the first completion notification is not delayed
  // by a cold spawn (a failed spawn is harmless; delivery falls back later).
  const socketPath = config.socketPath ?? defaultSocketPath();
  const serverPath = config.serverPath ?? defaultServerPath();
  void sendToDaemon(socketPath, { cmd: "ping" }).then((ok) => {
    if (!ok && daemonProcess === null) startDaemon(serverPath, socketPath);
  });
}
