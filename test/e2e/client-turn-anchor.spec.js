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
