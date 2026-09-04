/**
 * dsh-notify-macos — browser half (client module).
 *
 * Owns session navigation. The desktop daemon never touches the page: on
 * click it merely opens the GUI URL with a hash like
 *   http://127.0.0.1:3080/#dsh-notify-macos/session=<sessionId>
 * This bundle listens for that hash (both on load and on `hashchange`),
 * calls the frontend's native `sessions.open(id)` — no reload, no DOM
 * poking, no macOS automation permission — then strips the hash so the
 * next click re-triggers the listener.
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
     * Navigate to the session named by the hash, then clear the hash so a
     * later identical click fires `hashchange` again. The GUI is normally
     * long since booted when a card is clicked, so `sessions` is available;
     * if not (rare cold-open race), we wait a beat and retry rather than
     * dropping the jump.
     * @param getSessions - thunk returning the sessions service or undefined.
     */
    function openFromHash(getSessions) {
      const sessionId = sessionIdFromHash(window.location.hash);
      if (sessionId === undefined) return;

      const sessions = getSessions();
      if (sessions === undefined || typeof sessions.open !== "function") {
        // Not booted yet — retry briefly (hash stays until we succeed).
        setTimeout(() => openFromHash(getSessions), 250);
        return;
      }
      try {
        sessions.open(sessionId);
      } catch {
        /* unknown session — the GUI already shows its own state */
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
