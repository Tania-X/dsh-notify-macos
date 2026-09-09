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
      // The GUI needs a moment to switch sessions and render; then pin to
      // the newest message. (6s cap covers even slow history paging.)
      setTimeout(() => pinToNewest(6000), 150);

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
