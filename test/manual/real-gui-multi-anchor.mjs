// Manual diagnostic (needs a running `dsh web` at 127.0.0.1:3080):
// drives the REAL GUI with our deep link for MULTIPLE turn anchors at once and
// prints where each one lands — the client half per-row scroll, without needing
// the daemon or macOS Automation permission.
//
// Run: PLAYWRIGHT_BROWSERS_PATH=.pw-browsers node test/manual/real-gui-multi-anchor.mjs [turn ...]
import { chromium } from "@playwright/test";

const SID = process.env.DSH_NOTIFY_SESSION || "session-a937986d-3459-4bd1-ad01-821844404c20";
const turns = process.argv.slice(2).map(Number).filter((n) => Number.isFinite(n));
const ANCHORS = turns.length ? turns : [104, 98, 60, 1, 9999];

const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto("http://127.0.0.1:3080", { waitUntil: "domcontentloaded" });
await page.waitForFunction(() => document.querySelectorAll("[data-chat-anchor-key]").length > 0,
  { timeout: 40000 }).catch(() => {});
await page.waitForTimeout(2500);

const results = [];
for (const turn of ANCHORS) {
  const before = await page.evaluate(() => {
    const s = document.querySelector("[data-conversation-scroll]");
    return s ? { scrollHeight: s.scrollHeight, scrollTop: s.scrollTop } : null;
  });
  // Fire the deep link exactly like the daemon does.
  await page.evaluate((h) => { window.location.hash = h; },
    `#dsh-notify-macos/session=${SID}&turn=${turn}`);
  // No-anchor fallbacks (pinToNewest) settle later than a direct hit — give
  // them a longer window, otherwise the probe reads a mid-scroll position.
  await page.waitForTimeout(turn > 0 && turn <= 200 ? 9000 : 12000);
  const after = await page.evaluate((t) => {
    const s = document.querySelector("[data-conversation-scroll]");
    if (!s) return { error: "no scroller" };
    const rows = [...s.querySelectorAll("[data-chat-anchor-key]")];
    const sRect = s.getBoundingClientRect();
    const tail = rows.find((r) => (r.dataset.chatAnchorKey || "").endsWith(`:turn-tail${t}`));
    const top = tail ? tail.getBoundingClientRect().top - sRect.top : null;
    return {
      hash: location.hash || "(stripped)",
      rows: rows.length,
      scrollHeight: s.scrollHeight,
      scrollTop: Math.round(s.scrollTop),
      hasTail: !!tail,
      tailTop: top === null ? null : Math.round(top),
      clientHeight: s.clientHeight,
      inBand: top === null ? null : top > s.clientHeight * 0.4 && top < s.clientHeight * 0.8,
      atBottom: s.scrollTop >= s.scrollHeight - s.clientHeight - 2,
      // A fallback "pin to newest" puts the NEWEST row on screen; that is the
      // contract for an unreachable/unknown anchor (never worse than before).
      newestVisible: (() => {
        const last = rows[rows.length - 1];
        if (!last) return null;
        const t = last.getBoundingClientRect().top - sRect.top;
        return t > 0 && t < s.clientHeight;
      })(),
      maxScroll: s.scrollHeight - s.clientHeight,
    };
  }, turn);
  results.push({ turn, before, after });
  console.log(`turn=${String(turn).padEnd(5)} rows=${String(after.rows).padEnd(4)} ` +
    `scrollHeight=${before?.scrollHeight}->${after.scrollHeight} ` +
    `scrollTop=${after.scrollTop}/${after.maxScroll} ` +
    `hasTail=${after.hasTail} tailTop=${after.tailTop} inBand=${after.inBand} atBottom=${after.atBottom}`);
}
await browser.close();

// Expectations, by anchor class:
//   * an anchor the session really has  -> ITS OWN tail row, in the 40-80% band;
//   * an unknown/ancient anchor         -> fallback pin-to-newest (newest on screen).
// Ancient anchors can legitimately miss the band because the client's seek has a
// bounded paging budget (8s); that is a fallback, not a failure.
const failed = results.filter((r) => {
  const a = r.after;
  const anchored = a.hasTail && a.inBand;
  const fellBack = a.newestVisible === true;
  return !(anchored || fellBack);
});
console.log(`\n${results.length - failed.length}/${results.length} 符合预期` +
  (failed.length ? `；异常: ${failed.map((f) => f.turn).join(", ")}` : ""));
process.exit(failed.length ? 1 : 0);
