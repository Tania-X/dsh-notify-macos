// Position-indexed jumps (#3): the client must scroll to the completion of the
// turn named in the deep link (`...#dsh-notify-macos/session=<id>&turn=N`)
// instead of blindly pinning the session bottom.
import { test, expect } from "@playwright/test";

const HARNESS = "/test/e2e/harness/index.html";
const SID = "session-anchor";

async function gotoJump(page, hash) {
  await page.goto(`${HARNESS}#${hash}`);
  await page.waitForFunction(() => window.__test !== undefined);
  await expect
    .poll(() => page.evaluate(() => window.__test.openCalls()))
    .toEqual([SID]);
}

function rowTop(page, key) {
  return page.evaluate((k) => {
    const scroller = window.__test.scroller();
    const row = [...scroller.querySelectorAll("[data-chat-anchor-key]")]
      .find((r) => r.dataset.chatAnchorKey === k);
    if (!row) return null;
    return {
      topInViewport: row.getBoundingClientRect().top - scroller.getBoundingClientRect().top,
      clientHeight: scroller.clientHeight,
      scrollTop: scroller.scrollTop,
      maxScrollTop: scroller.scrollHeight - scroller.clientHeight,
    };
  }, key);
}

test("turn anchor scrolls that turn's completion into view (not the bottom)", async ({ page }) => {
  await gotoJump(page, `dsh-notify-macos/session=${SID}&turn=3`);
  // The client scrolls ~150ms after open; poll until the row sits in the
  // 40–80% band of the viewport (its completion position, not the bottom).
  await expect
    .poll(
      async () => {
        const m = await rowTop(page, "9:turn-tail3");
        if (m === null) return "missing";
        return m.topInViewport > m.clientHeight * 0.4 && m.topInViewport < m.clientHeight * 0.8
          ? "in-band"
          : m.topInViewport;
      },
      { timeout: 8000 }
    )
    .toBe("in-band");
  const m = await rowTop(page, "9:turn-tail3");
  expect(m.topInViewport).toBeGreaterThan(m.clientHeight * 0.4);
  expect(m.topInViewport).toBeLessThan(m.clientHeight * 0.8);
  // …and NOT pinned to the session bottom.
  expect(m.scrollTop).toBeLessThan(m.maxScrollTop - 10);
});

test("missing turn falls back to pinning the newest message", async ({ page }) => {
  await gotoJump(page, `dsh-notify-macos/session=${SID}&turn=99`);
  await expect
    .poll(async () => {
      const m = await page.evaluate(() => {
        const s = window.__test.scroller();
        return { scrollTop: s.scrollTop, max: s.scrollHeight - s.clientHeight };
      });
      return m.max > 0 && m.scrollTop >= m.max - 2;
    }, { timeout: 10000 })
    .toBe(true);
});

test("plain session jump (no turn) still pins the bottom", async ({ page }) => {
  await gotoJump(page, `dsh-notify-macos/session=${SID}`);
  await expect
    .poll(async () => {
      const m = await page.evaluate(() => {
        const s = window.__test.scroller();
        return { scrollTop: s.scrollTop, max: s.scrollHeight - s.clientHeight };
      });
      return m.max > 0 && m.scrollTop >= m.max - 2;
    }, { timeout: 10000 })
    .toBe(true);
});

test("anchor re-aligns when history pages in above it", async ({ page }) => {
  await gotoJump(page, `dsh-notify-macos/session=${SID}&turn=3`);
  const inBand = async () => {
    const m = await rowTop(page, "9:turn-tail3");
    return m !== null && m.topInViewport > m.clientHeight * 0.4 && m.topInViewport < m.clientHeight * 0.8;
  };
  await expect.poll(inBand, { timeout: 8000 }).toBe(true);
  // Older messages arrive above the anchor (real GUI pages history in).
  await page.evaluate(() => window.__test.prependRows(3, 300));
  await expect.poll(inBand, { timeout: 8000 }).toBe(true);
});

test("seeks older history when the anchored turn is not rendered yet", async ({ page }) => {
  // Lazy harness: only turns 4-6 exist until the scrollport reaches the top.
  await page.goto(`${HARNESS}?lazy=1#dsh-notify-macos/session=${SID}&turn=1`);
  await page.waitForFunction(() => window.__test !== undefined);
  await expect
    .poll(() => page.evaluate(() => window.__olderPagesLoaded ?? 0), { timeout: 10000 })
    .toBeGreaterThan(0);   // the client walked upwards and triggered a page load
  expect(await page.evaluate(() => window.__decoyClicks ?? 0)).toBe(0);   // never mis-click
  await expect
    .poll(async () => {
      const m = await rowTop(page, "9:turn-tail1");
      if (m === null) return "missing";
      return m.topInViewport > m.clientHeight * 0.4 && m.topInViewport < m.clientHeight * 0.8
        ? "in-band"
        : m.topInViewport;
    }, { timeout: 12000 })
    .toBe("in-band");
});

test("seek never clicks unrelated history-looking controls", async ({ page }) => {
  await page.goto(`${HARNESS}?lazy=1#dsh-notify-macos/session=${SID}&turn=1`);
  await page.waitForFunction(() => window.__test !== undefined);
  await page.waitForTimeout(2000);
  expect(await page.evaluate(() => window.__decoyClicks ?? 0)).toBe(0);
  expect(await page.evaluate(() => window.__olderPagesLoaded ?? 0)).toBeGreaterThan(0);
});
