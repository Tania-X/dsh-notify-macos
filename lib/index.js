/**
 * dsh-notify-macos — DSH host plugin.
 *
 * Shows a native macOS notification (top-right corner) every time a
 * conversation/turn completes, so the user knows the task is done even when
 * the browser tab is in the background.
 *
 * Signals: listens for the agent-scoped `agent/status` event and detects the
 * `running -> idle` transition. Because an agent stays `running` across all
 * queued turns and only returns to `idle` once the whole batch drains, this
 * fires exactly once per completed conversation round.
 *
 * The notification is fired with `osascript -e 'display notification …'`,
 * which is the standard way to raise a native macOS notification without any
 * extra dependency.
 *
 * @module dsh-notify-macos
 */
import { spawn } from "node:child_process";
import z from "@deepseek-ai/schemastery";

/** Stable Cordis plugin name. */
export const name = "dsh-notify-macos";

/** Services required before the plugin activates. */
export const inject = ["agents", "sessionTitle"];

/** Plugin configuration schema. */
export const Config = z.object({
  /** Master switch; setting false disables all notifications. */
  enabled: z.boolean().default(true),
  /** Notification title (also used as the macOS notification's `title`). */
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
  rootOnly: z.boolean().default(true)
});

/**
 * Escape a value into a safe AppleScript double-quoted string literal.
 * JSON.stringify is a close-enough superset for the characters that can
 * appear in titles/messages.
 */
function appleScriptString(value) {
  return JSON.stringify(String(value).replace(/[\n\r\t]/g, " "));
}

/**
 * Fire a native macOS notification via osascript.
 * @param title - notification title.
 * @param message - notification body.
 * @param sound - whether to play the system "Glass" sound.
 */
function notify(title, message, sound) {
  const script = `display notification ${appleScriptString(message)} with title ${appleScriptString(title)}${sound ? ' sound name "Glass"' : ""}`;
  const child = spawn("osascript", ["-e", script], {
    stdio: "ignore",
    detached: false
  });
  child.on("error", (error) => {
    console.error("[dsh-notify-macos] osascript failed:", error.message);
  });
  child.unref?.();
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
    notify(title, body, sound);
  });
}
