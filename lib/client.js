/**
 * dsh-notify-macos — browser half (client module).
 *
 * Owns session navigation. The desktop daemon never touches the page: on
 * click it merely opens the GUI URL with a hash like
 *   http://127.0.0.1:3080/#dsh-notify-macos/session=<sessionId>
 * This bundle listens for that hash (both on load and on `hashchange`),
 * calls the frontend's native `sessions.open(id)`, then pins the chat
 * scrollport to the newest message (the "task done" spot) — no reload, no
 * DOM poking, no macOS automation permission. The hash is stripped so the
 * next click re-triggers the listener.
 *
 * Why scroll here instead of relying on the GUI: opening a session restores
 * its last scroll position when one was saved (e.g. the user had scrolled
 * up earlier), so a jump must explicitly bring the newest message into
 * view.
 *
 * Packaged as the module-loader factory format the web shell loads for
 * every `dsh.client` entry (see package.json's `dsh.client` / `exports`).
 */
window.__ModuleLoader__.load({
  id: "dsh-notify-macos",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

    /** Namespace prefix for this plugin's deep-link hashes. */
    const HASH_PREFIX = "dsh-notify-macos/session=";

    /**
     * Parse a session id out of the current URL hash, if it targets us.
     * @param hash - `window.location.hash` (may be empty).
     * @returns the session id, or undefined.
     */
    function sessionIdFromHash(hash) {
      const index = hash.indexOf(HASH_PREFIX);
      if (index === -1) return undefined;
      const raw = hash.slice(index + HASH_PREFIX.length);
      const end = raw.indexOf("&");
      const value = (end === -1 ? raw : raw.slice(0, end)).trim();
      if (value.length === 0) return undefined;
      try {
        return decodeURIComponent(value);
      } catch {
        return value;
      }
    }

    /**
     * Parse the turn anchor (`...#dsh-notify-macos/session=<id>&turn=12`).
     * @param hash - `window.location.hash` (may be empty).
     * @returns the turn number, or undefined.
     */
    function turnFromHash(hash) {
      const index = hash.indexOf("&turn=");
      if (index === -1) return undefined;
      const raw = hash.slice(index + "&turn=".length);
      const end = raw.indexOf("&");
      const value = (end === -1 ? raw : raw.slice(0, end)).trim();
      const turn = Number.parseInt(value, 10);
      return Number.isFinite(turn) && turn > 0 ? turn : undefined;
    }

    /**
     * The rendered row that marks the END of `turn` (the GUI tags every flow
     * row with `data-chat-anchor-key`; a finished turn carries `…:turn-tail<N>`,
     * and its assistant steps carry `…assistant-step<N>:…` as a fallback).
     * @param scroller - the conversation scrollport.
     * @param turn - turn number.
     * @returns the row element, or null.
     */
    function turnAnchorElement(scroller, turn) {
      const rows = scroller.querySelectorAll("[data-chat-anchor-key]");
      let stepFallback = null;
      for (const row of rows) {
        const key = row.dataset.chatAnchorKey ?? "";
        if (key.endsWith(":turn-tail" + turn)) return row;
        if (stepFallback === null && key.includes("assistant-step" + turn + ":")) {
          stepFallback = row;
        }
      }
      return stepFallback;
    }

    /**
     * The GUI's "load older history" control, if it is rendered and not busy.
     * CSS modules keep the local class name after the hash (`<hash>_older`), and
     * the label is localized, so match both defensively.
     * @param scroller - the conversation scrollport.
     * @returns the button element, or null.
     */
    function loadOlderButton(scroller) {
      // Prefer the GUI's own control: CSS modules keep the local name after the
      // hash, so `<hash>_older` is stable build to build.
      // Only a button carrying the local class, or a wrapper whose class ENDS
      // with `_older`: `[class*="_older"]` alone also matches `_olderHint`-style
      // containers and would bypass the label filter below.
      const byClass = scroller.querySelector('button[class*="_older"], [class$="_older"] > button');
      if (byClass !== null && byClass.disabled !== true) return byClass;
      // Locale-tolerant fallback. Deliberately narrow: a bare "加载"/"历史" can
      // label an unrelated control (history panel, load-more), and mis-clicking
      // it every tick would fire unintended actions.
      for (const button of scroller.querySelectorAll("button")) {
        if (button.disabled === true) continue;
        const label = (button.textContent ?? "").trim();
        if (label.length === 0 || label.length >= 24) continue;
        if (/loading|加载中|请稍候/i.test(label)) continue;
        if (/older|earlier|更早|加载(更早|更多|历史)/i.test(label)) return button;
      }
      return null;
    }

    /**
     * Scroll this turn's completion into view (~60% down the viewport, so the
     * finished output stays readable above it) instead of jumping to the
     * session bottom. Calls `onMiss` when the turn never renders (e.g. the row
     * is on a history page that was not loaded).
     * @param turn - turn number from the deep link.
     * @param timeoutMs - how long to wait for the row.
     * @param onMiss - fallback when the anchor is not found in time.
     */
    function scrollToTurn(turn, timeoutMs, onMiss) {
      const deadline = Date.now() + timeoutMs;
      let lastHeight = -1;
      let stableRounds = 0;
      let found = false;
      // Seeking older history: at most one button click per 500ms, and stop
      // after a few clicks that loaded nothing new.
      let lastClickAt = 0;
      let heightAfterClick = -1;
      let clicksWithoutGrowth = 0;
      const tick = () => {
        const scroller = document.querySelector("[data-conversation-scroll]");
        if (scroller !== null) {
          const row = turnAnchorElement(scroller, turn);
          if (row !== null) {
            found = true;
            // Re-align every tick: the GUI pages history in ABOVE the anchor,
            // which pushes the row away from where we first placed it.
            const target = scroller.clientHeight * 0.6;
            const delta = row.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
            if (Math.abs(delta - target) > 4) scroller.scrollTop += delta - target;
            if (scroller.scrollHeight === lastHeight) stableRounds += 1;
            else stableRounds = 0;
            lastHeight = scroller.scrollHeight;
            if (stableRounds >= 3) return;   // layout settled → anchor is home
          } else {
            // The row is not rendered: the GUI keeps only a window of recent
            // rows and pages older history in through an explicit button at the
            // top. Click it (bounded by the deadline) while also walking up.
            const now = Date.now();
            if (now - lastClickAt >= 500) {
              // Judge the previous click once per window (was anything loaded?),
              // then click again only while pages keep arriving.
              const grew = heightAfterClick < 0 || scroller.scrollHeight > heightAfterClick;
              clicksWithoutGrowth = grew ? 0 : clicksWithoutGrowth + 1;
              const older = loadOlderButton(scroller);
              if (older !== null && clicksWithoutGrowth < 3) {
                lastClickAt = now;
                heightAfterClick = scroller.scrollHeight;
                older.click();
              }
            }
            // Keep walking upwards regardless, so seeking never stalls while the
            // click is throttled or no paging control exists.
            const step = Math.max(120, scroller.clientHeight * 2);
            if (scroller.scrollTop > 0) {
              scroller.scrollTop = Math.max(0, scroller.scrollTop - step);
            }
          }
        }
        if (Date.now() < deadline) {
          setTimeout(tick, 150);
        } else if (!found && typeof onMiss === "function") {
          onMiss();
        }
      };
      tick();
    }

    /**
     * Keep scrolling the conversation scrollport to its bottom until the
     * content stops growing (long histories load in pages). The GUI's own
     * scroll handler observes these assignments and records the position as
     * at-bottom, so this composes with — not fights — its state.
     * @param timeoutMs - how long to keep trying before giving up.
     */
    function pinToNewest(timeoutMs) {
      const deadline = Date.now() + timeoutMs;
      let lastHeight = -1;
      let stableRounds = 0;
      const tick = () => {
        const scroller = document.querySelector("[data-conversation-scroll]");
        if (scroller !== null) {
          scroller.scrollTop = scroller.scrollHeight;
          if (scroller.scrollHeight === lastHeight) stableRounds += 1;
          else stableRounds = 0;
          lastHeight = scroller.scrollHeight;
          // Content stable for a few rounds → we are at the newest message.
          if (stableRounds >= 3) return;
        }
        if (Date.now() < deadline) setTimeout(tick, 120);
      };
      tick();
    }

    /**
     * Navigate to the session named by the hash, pin to its newest message,
     * then clear the hash so a later identical click fires `hashchange`
     * again. If `sessions` is not booted yet (rare cold-open race), retry
     * briefly rather than dropping the jump.
     * @param getSessions - thunk returning the sessions service or undefined.
     */
    function openFromHash(getSessions) {
      const sessionId = sessionIdFromHash(window.location.hash);
      if (sessionId === undefined) return;

      const turn = turnFromHash(window.location.hash);
      const sessions = getSessions();
      if (sessions === undefined || typeof sessions.open !== "function") {
        // Not booted yet — retry (hash stays until we succeed).
        setTimeout(() => openFromHash(getSessions), 250);
        return;
      }
      try {
        sessions.open(sessionId);
      } catch {
        /* unknown session — the GUI already shows its own state */
      }
      // The GUI needs a moment to switch sessions and render. With a turn
      // anchor we scroll to that turn's completion; without one (or when the
      // row never renders) we keep the old behaviour and pin the newest
      // message. (6s cap covers even slow history paging.)
      if (turn === undefined) {
        setTimeout(() => pinToNewest(6000), 150);
      } else {
        setTimeout(() => scrollToTurn(turn, 8000, () => pinToNewest(6000)), 150);
      }

      // Drop the hash without adding a history entry or reloading.
      try {
        const clean = window.location.href.split("#")[0];
        window.history.replaceState(null, "", clean);
      } catch {
        /* history API unavailable — hash stays, harmless */
      }
    }

    /** Client plugin name. */
    const name = "dsh-notify-macos";

    /** Services we wait on before wiring (mirrors the runtime's own order). */
    const inject = ["remote"];

    /**
     * Plugin entry: wire the hash listener once the client runtime is up.
     * @param ctx - client Cordis context.
     */
    function apply(ctx) {
      const getSessions = () => ctx.get("sessions");
      const onChange = () => openFromHash(getSessions);
      window.addEventListener("hashchange", onChange);
      // Cover the case where the page was opened directly on a jump hash.
      openFromHash(getSessions);

      ctx.effect(() => {
        return () => window.removeEventListener("hashchange", onChange);
      }, "dsh-notify-macos: hash listener");
    }

    exports.apply = apply;
    exports.inject = inject;
    exports.name = name;
    return module.exports;
  }
});
