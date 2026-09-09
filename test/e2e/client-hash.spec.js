// Playwright specs for the client half (lib/client.js), driven through a
// minimal harness page that stubs the web shell (__ModuleLoader__ + a fake
// "sessions" service) — no real dsh web instance needed.
//
// These encode the CURRENT navigation contract (jump = open session, pin
// scrollport to newest, strip the hash). When "position-indexed jumps"
// arrive, the contract here is what changes first.
import { test, expect } from "@playwright/test";

const HARNESS = "/test/e2e/harness/index.html";
const PREFIX = "dsh-notify-macos/session=";

async function gotoHash(page, hash) {
  await page.goto(`${HARNESS}#${hash}`);
  // apply() runs on load; wait until the harness is wired.
  await page.waitForFunction(() => window.__test !== undefined);
}

async function openCalls(page) {
  return page.evaluate(() => window.__test.openCalls());
}

test("on-load jump hash opens the session and is stripped", async ({ page }) => {
  await gotoHash(page, `${PREFIX}session-abc`);
  await expect.poll(() => openCalls(page)).toEqual(["session-abc"]);
  // The hash must be cleared so a later identical click re-fires hashchange.
  await expect
    .poll(() => page.evaluate(() => window.location.hash))
    .toBe("");
});

test("hashchange (daemon click) opens the session and strips the hash", async ({ page }) => {
  await page.goto(HARNESS);
  await page.waitForFunction(() => window.__test !== undefined);
  await page.evaluate((h) => { window.location.hash = h; }, `#${PREFIX}session-xyz`);
  await expect.poll(() => openCalls(page)).toEqual(["session-xyz"]);
  await expect
    .poll(() => page.evaluate(() => window.location.hash))
    .toBe("");
});

test("empty / non-target hashes never open a session", async ({ page }) => {
  await page.goto(HARNESS);
  await page.waitForFunction(() => window.__test !== undefined);
  // not our prefix
  await page.evaluate(() => { window.location.hash = "#other/session=x"; });
  // our prefix but no id — openFromHash returns before scheduling anything
  await page.evaluate(() => { window.location.hash = `#${"dsh-notify-macos/session="}`; });
  // No asynchronous work can be pending (sessionId is undefined), so an
  // immediate poll is a faithful "never opened" assertion.
  await expect.poll(() => openCalls(page)).toEqual([]);
});

test("jump pins the [data-conversation-scroll] viewport to the newest message", async ({ page }) => {
  await gotoHash(page, `${PREFIX}session-scroll`);
  await expect.poll(() => openCalls(page)).toEqual(["session-scroll"]);
  // pinToNewest polls until the content stops growing; give it time, then the
  // scroller must sit at its bottom.
  const contentHeight = await page.evaluate(() => window.__test.contentHeight());
  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const scroller = window.__test.scroller();
          if (!scroller) return 0; // not found yet — keep polling
          return scroller.scrollTop + scroller.clientHeight;
        }),
      { timeout: 8000 }
    )
    .toBeGreaterThanOrEqual(contentHeight - 2);
});

test("retries opening until the sessions service is booted", async ({ page }) => {
  await page.goto(HARNESS);
  await page.waitForFunction(() => window.__test !== undefined);
  // Simulate the cold-open race: sessions not booted yet.
  await page.evaluate(() => window.__test.setSessionsBooted(false));
  await page.evaluate((h) => { window.location.hash = h; }, `#${PREFIX}session-late`);
  // The initial attempt returns no service and schedules a retry (every
  // 250ms). Wait until at least one RETRY happened while still down, which
  // proves the retry path — then boot the service.
  await expect
    .poll(() => page.evaluate(() => window.__test.sessionsGets()))
    .toBeGreaterThanOrEqual(2);
  await page.evaluate(() => window.__test.setSessionsBooted(true));
  await expect.poll(() => openCalls(page)).toEqual(["session-late"]);
  await expect
    .poll(() => page.evaluate(() => window.location.hash))
    .toBe("");
});

test("cleanup removes the hashchange listener", async ({ page }) => {
  await page.goto(HARNESS);
  await page.waitForFunction(() => window.__test !== undefined);
  await page.evaluate(() => window.__test.cleanup());
  await page.evaluate((h) => { window.location.hash = h; }, `#${PREFIX}session-after-cleanup`);
  // No listener is left, so nothing can schedule an open or strip the hash.
  await expect.poll(() => openCalls(page)).toEqual([]);
  expect(await page.evaluate(() => window.location.hash)).toContain(PREFIX);
});
