import XCTest
@testable import dshNotifyCore

final class OutcomeKindTests: XCTestCase {
    func testParseDefaultsToCompleted() {
        XCTAssertEqual(OutcomeKind.parse(nil), .completed)
        XCTAssertEqual(OutcomeKind.parse(""), .completed)
        XCTAssertEqual(OutcomeKind.parse("weird"), .completed)
    }

    func testParseKnownKinds() {
        XCTAssertEqual(OutcomeKind.parse("completed"), .completed)
        XCTAssertEqual(OutcomeKind.parse("error"), .error)
        XCTAssertEqual(OutcomeKind.parse("blocked"), .blocked)
    }
}

final class JumpPolicyTests: XCTestCase {
    /// Names as the daemon resolves them at runtime (channels, not families).
    private let probeNames = ["Safari", "Google Chrome", "Microsoft Edge Dev"]

    func testProbeOrderWithoutPreferenceKeepsGivenOrder() {
        XCTAssertEqual(JumpPolicy.probeOrder(candidates: probeNames, preferring: nil), probeNames)
    }

    func testProbeOrderMovesLastSuccessToFrontPreservingRest() {
        let order = JumpPolicy.probeOrder(candidates: probeNames, preferring: "Microsoft Edge Dev")
        XCTAssertEqual(order, ["Microsoft Edge Dev", "Safari", "Google Chrome"])
        XCTAssertEqual(Set(order), Set(probeNames))
    }

    func testProbeOrderUnknownPreferenceIsIgnored() {
        XCTAssertEqual(JumpPolicy.probeOrder(candidates: probeNames, preferring: "Firefox"), probeNames)
    }

    // MARK: Activation visibility (the "card vanished, nothing jumped" bug)

    func testEscalatesActivationOnlyWhenBrowserDidNotComeForward() {
        XCTAssertTrue(JumpPolicy.shouldEscalateActivation(browserIsFrontmost: false))
        XCTAssertFalse(JumpPolicy.shouldEscalateActivation(browserIsFrontmost: true))
    }

    func testJumpIsVisibleOnlyWhenNavigatedAndBrowserIsFrontmost() {
        XCTAssertTrue(JumpPolicy.isVisibleToUser(navigated: true, browserIsFrontmost: true))
        XCTAssertFalse(JumpPolicy.isVisibleToUser(navigated: true, browserIsFrontmost: false))
        XCTAssertFalse(JumpPolicy.isVisibleToUser(navigated: false, browserIsFrontmost: true))
        XCTAssertFalse(JumpPolicy.isVisibleToUser(navigated: false, browserIsFrontmost: false))
    }

    func testActivationWaitBudgetIsBounded() {
        // A clicked card must not hang the UI thread waiting for the browser.
        XCTAssertGreaterThan(JumpPolicy.activationSettleSeconds, 0)
        XCTAssertLessThanOrEqual(JumpPolicy.activationSettleSeconds, 2)
        XCTAssertGreaterThan(JumpPolicy.activationPollSeconds, 0)
        XCTAssertLessThan(JumpPolicy.activationPollSeconds, JumpPolicy.activationSettleSeconds)
    }

    func testOnlyUnconfirmedKeepsTheCard() {
        // `visible` is done; `notApplicable` was never a position jump; only
        // `unconfirmed` keeps the card so the click can be retried. (A bare
        // Bool here previously let "no session id"/"open-folder" report success
        // without ever checking anything — AI review, severity 4.)
        XCTAssertTrue(JumpPolicy.shouldDismissCard(after: .visible))
        XCTAssertTrue(JumpPolicy.shouldDismissCard(after: .notApplicable))
        XCTAssertFalse(JumpPolicy.shouldDismissCard(after: .unconfirmed))
    }

    // MARK: Window-level visibility (app frontmost ≠ hosting window shown)

    func testBoundsMatchToleratesSmallDisagreement() {
        let host = JumpPolicy.WindowBounds(x: 100, y: 50, width: 1200, height: 800)
        XCTAssertTrue(JumpPolicy.boundsMatch(host, JumpPolicy.WindowBounds(x: 104, y: 46, width: 1204, height: 796)))
        XCTAssertFalse(JumpPolicy.boundsMatch(host, JumpPolicy.WindowBounds(x: 140, y: 50, width: 1200, height: 800)))
        XCTAssertFalse(JumpPolicy.boundsMatch(host, JumpPolicy.WindowBounds(x: 100, y: 50, width: 900, height: 800)))
    }

    func testBoundsToleranceIsTooTightToConfuseNeighbourWindows() {
        let host = JumpPolicy.WindowBounds(x: 0, y: 25, width: 1440, height: 875)
        // A same-sized window shifted a few pixels is a DIFFERENT window.
        XCTAssertFalse(JumpPolicy.boundsMatch(host, JumpPolicy.WindowBounds(x: 12, y: 25, width: 1440, height: 875)))
        // A different-sized window in the same place is a different window too.
        XCTAssertFalse(JumpPolicy.boundsMatch(host, JumpPolicy.WindowBounds(x: 0, y: 25, width: 1430, height: 875)))
        // Rounding-level disagreement is still accepted.
        XCTAssertTrue(JumpPolicy.boundsMatch(host, JumpPolicy.WindowBounds(x: 1, y: 26, width: 1441, height: 874)))
    }

    func testUnknownWindowStateIsNotTreatedAsVisible() {
        // `nil` (browser could not report the window frame) tends to happen
        // exactly when the window is minimized/off-Space, so it must escalate
        // instead of passing as "visible" — the defect this rule closes.
        XCTAssertTrue(JumpPolicy.shouldEscalateForWindow(windowOnScreen: nil, appIsFrontmost: true))
        XCTAssertFalse(JumpPolicy.shouldEscalateForWindow(windowOnScreen: true, appIsFrontmost: true))
        XCTAssertFalse(JumpPolicy.visibilityVerdict(windowOnScreen: false, appIsFrontmost: true))
        XCTAssertTrue(JumpPolicy.visibilityVerdict(windowOnScreen: nil, appIsFrontmost: true))
        XCTAssertFalse(JumpPolicy.visibilityVerdict(windowOnScreen: true, appIsFrontmost: false))
    }

    func testHostingWindowIsRecognisedOnlyWhenOnScreen() {
        let host = JumpPolicy.WindowBounds(x: 0, y: 25, width: 1440, height: 875)
        let otherSpaceWindow = JumpPolicy.WindowBounds(x: 200, y: 100, width: 900, height: 600)
        XCTAssertTrue(JumpPolicy.isWindowOnScreen(host, among: [otherSpaceWindow, host]))
        XCTAssertFalse(JumpPolicy.isWindowOnScreen(host, among: [otherSpaceWindow]))
        XCTAssertFalse(JumpPolicy.isWindowOnScreen(host, among: []))
    }

    func testShouldRetryOnlyWhenDeniedAndPassesRemain() {
        XCTAssertTrue(JumpPolicy.shouldRetry(afterPass: 1, sawDenied: true))
        XCTAssertTrue(JumpPolicy.shouldRetry(afterPass: 2, sawDenied: true))
        XCTAssertFalse(JumpPolicy.shouldRetry(afterPass: 3, sawDenied: true), "no retry after the last pass")
        XCTAssertFalse(JumpPolicy.shouldRetry(afterPass: 1, sawDenied: false), "clean pass needs no retry")
        XCTAssertEqual(JumpPolicy.maxProbePasses, 3)
        XCTAssertEqual(JumpPolicy.retryDelaySeconds, 0.5)
    }

    func testCatalogShape() {
        XCTAssertEqual(BrowserCatalog.families.map(\.key),
                       ["Safari", "Google Chrome", "Microsoft Edge", "Brave Browser", "Arc", "Opera"])
        XCTAssertEqual(BrowserCatalog.families.first?.channels,
                       [BrowserChannel(appName: "Safari", bundleId: "com.apple.Safari")])
        // every channel must carry an AppleScript-resolvable name + bundle id
        for family in BrowserCatalog.families {
            XCTAssertFalse(family.channels.isEmpty, "\(family.key) has no channels")
            for channel in family.channels {
                XCTAssertFalse(channel.appName.isEmpty)
                XCTAssertFalse(channel.bundleId.isEmpty)
            }
        }
    }

    func testRunningChannelResolvesInstalledChannel() {
        let edge = BrowserCatalog.families.first { $0.key == "Microsoft Edge" }!
        // Only Edge Dev installed (the machine that surfaced the -2740 bug):
        // AppleScript needs "Microsoft Edge Dev", NOT "Microsoft Edge".
        XCTAssertEqual(
            BrowserCatalog.runningChannel(for: edge, runningBundleIds: ["com.microsoft.edgemac.Dev"])?.appName,
            "Microsoft Edge Dev"
        )
        // Stable + Dev both running → prefer the stable build.
        XCTAssertEqual(
            BrowserCatalog.runningChannel(
                for: edge, runningBundleIds: ["com.microsoft.edgemac", "com.microsoft.edgemac.Dev"]
            )?.appName,
            "Microsoft Edge"
        )
        XCTAssertNil(BrowserCatalog.runningChannel(for: edge, runningBundleIds: ["com.apple.Safari"]))
    }

    func testChannelReverseLookup() {
        XCTAssertEqual(BrowserCatalog.channel(appName: "Microsoft Edge Dev")?.bundleId,
                       "com.microsoft.edgemac.Dev")
        XCTAssertEqual(BrowserCatalog.channel(appName: "Safari")?.bundleId, "com.apple.Safari")
        XCTAssertNil(BrowserCatalog.channel(appName: "Firefox"))
    }

    func testProbeOrderOnlyIncludesRunningBrowsers() {
        // Safari + Edge Dev running; Edge must be named by its channel.
        XCTAssertEqual(
            BrowserCatalog.probeOrder(runningBundleIds: ["com.apple.Safari", "com.microsoft.edgemac.Dev"],
                                      preferring: nil),
            ["Safari", "Microsoft Edge Dev"]
        )
        // Last successful browser jumps the queue.
        XCTAssertEqual(
            BrowserCatalog.probeOrder(runningBundleIds: ["com.apple.Safari", "com.microsoft.edgemac.Dev"],
                                      preferring: "Microsoft Edge Dev"),
            ["Microsoft Edge Dev", "Safari"]
        )
        // Nothing running → nothing to probe (no fallback churn).
        XCTAssertEqual(BrowserCatalog.probeOrder(runningBundleIds: [], preferring: nil), [])
    }

    func testFallbackOnlyWhenNoDenial() {
        // Denied pass: the browser is there but undrivable — opening a URL would
        // spawn a new tab and reload the GUI, so it must be refused.
        XCTAssertFalse(JumpPolicy.shouldOpenFallback(sawDenied: true))
        // Clean pass (browser reachable, no hosting tab) → GUI is not open.
        XCTAssertTrue(JumpPolicy.shouldOpenFallback(sawDenied: false))
    }
}
