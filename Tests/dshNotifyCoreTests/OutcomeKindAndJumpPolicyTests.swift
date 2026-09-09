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
        XCTAssertEqual(BrowserCatalog.candidates, [
            "Safari", "Google Chrome", "Microsoft Edge", "Brave Browser", "Arc", "Opera",
        ])
        for name in BrowserCatalog.candidates {
            XCTAssertNotNil(BrowserCatalog.bundleIds[name], "bundle ids missing for \(name)")
            XCTAssertFalse(BrowserCatalog.bundleIds[name]!.isEmpty)
        }
        XCTAssertEqual(BrowserCatalog.bundleIds["Safari"], ["com.apple.Safari"])
    }
}
