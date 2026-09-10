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
    func testProbeOrderWithoutPreferenceKeepsCatalogOrder() {
        XCTAssertEqual(JumpPolicy.probeOrder(candidates: BrowserCatalog.candidates, preferring: nil),
                       BrowserCatalog.candidates)
    }

    func testProbeOrderMovesLastSuccessToFrontPreservingRest() {
        let order = JumpPolicy.probeOrder(
            candidates: BrowserCatalog.candidates,
            preferring: "Microsoft Edge"
        )
        XCTAssertEqual(order.first, "Microsoft Edge")
        XCTAssertEqual(Set(order), Set(BrowserCatalog.candidates))
    }

    func testProbeOrderUnknownPreferenceIsIgnored() {
        XCTAssertEqual(JumpPolicy.probeOrder(candidates: BrowserCatalog.candidates, preferring: "Firefox"),
                       BrowserCatalog.candidates)
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
