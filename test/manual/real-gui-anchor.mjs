// Manual diagnostic (needs a running `dsh web` at 127.0.0.1:3080):
// drives the REAL GUI with our deep link and prints where the anchored turn
// lands, so the client behaviour can be checked against the real DOM.
// Run: PLAYWRIGHT_BROWSERS_PATH=.pw-browsers node test/manual/real-gui-anchor.mjs
import { chromium } from "@playwright/test";
const SID = "session-a937986d-3459-4bd1-ad01-821844404c20";
const b = await chromium.launch();
const p = await b.newPage();
await p.goto("http://127.0.0.1:3080", { waitUntil: "domcontentloaded" });
await p.waitForTimeout(6000);
try { await p.getByText("DeepSeek插件任务完成提醒", { exact: false }).first().click({ timeout: 15000 }); } catch {}
try { await p.waitForFunction(() => document.querySelectorAll("[data-chat-anchor-key]").length > 0, { timeout: 30000 }); } catch {}
await p.waitForTimeout(1500);
const before = await p.evaluate(() => {
  const s = document.querySelector("[data-conversation-scroll]");
  const rows = [...s.querySelectorAll("[data-chat-anchor-key]")];
  const tail = rows.find(r => (r.dataset.chatAnchorKey || "").endsWith(":turn-tail91"));
  return { scrollTop: s.scrollTop, max: s.scrollHeight - s.clientHeight, hasTail91: !!tail,
           tailTop: tail ? tail.getBoundingClientRect().top - s.getBoundingClientRect().top : null,
           clientHeight: s.clientHeight, rowCount: rows.length };
});
console.log("BEFORE:", JSON.stringify(before));
// fire our deep link exactly like the daemon does
await p.evaluate((h) => { window.location.hash = h; }, `#dsh-notify-macos/session=${SID}&turn=91`);
await p.waitForTimeout(4000);
const after = await p.evaluate(() => {
  const s = document.querySelector("[data-conversation-scroll]");
  const rows = [...s.querySelectorAll("[data-chat-anchor-key]")];
  const tail = rows.find(r => (r.dataset.chatAnchorKey || "").endsWith(":turn-tail91"));
  return { hash: location.hash, scrollTop: s.scrollTop, max: s.scrollHeight - s.clientHeight,
           tailTop: tail ? tail.getBoundingClientRect().top - s.getBoundingClientRect().top : null,
           clientHeight: s.clientHeight,
           inBand: tail ? (tail.getBoundingClientRect().top - s.getBoundingClientRect().top) > s.clientHeight * 0.4
                          && (tail.getBoundingClientRect().top - s.getBoundingClientRect().top) < s.clientHeight * 0.8 : null,
           atBottom: s.scrollTop >= s.scrollHeight - s.clientHeight - 2 };
});
console.log("AFTER :", JSON.stringify(after));
await b.close();
