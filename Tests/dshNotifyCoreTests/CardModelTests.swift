import XCTest
@testable import dshNotifyCore

/// Deterministic "HH:mm" formatting helper mirroring CardModel.summaryLine so
/// assertions don't depend on locale/timezone drift within one process.
private func hhmm(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

final class CardModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_060)

    func testAddCompletionAssignsContiguousIndexesInArrivalOrder() {
        let m = CardModel()
        XCTAssertEqual(m.addCompletion(message: "a", kind: .completed, detail: nil, at: t0), 1)
        XCTAssertEqual(m.addCompletion(message: "b", kind: .error, detail: "boom", at: t1), 2)
        XCTAssertEqual(m.completionCount, 2)
        XCTAssertEqual(m.entries.map(\.index), [1, 2])
        XCTAssertEqual(m.entries.map(\.message), ["a", "b"])
        XCTAssertEqual(m.newestEntry?.message, "b")
    }

    func testRemoveCompletionReindexesContiguously() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        m.addCompletion(message: "b", kind: .error, detail: nil, at: t0)
        m.addCompletion(message: "c", kind: .blocked, detail: nil, at: t1)
        let removed = m.removeCompletion(index: 2)   // remove "b"
        XCTAssertEqual(removed?.message, "b")
        XCTAssertEqual(m.entries.map(\.message), ["a", "c"])
        XCTAssertEqual(m.entries.map(\.index), [1, 2], "indexes must stay contiguous")
    }

    func testRemoveCompletionOutOfRangeReturnsNil() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        XCTAssertNil(m.removeCompletion(index: 0))
        XCTAssertNil(m.removeCompletion(index: 2))
        XCTAssertEqual(m.completionCount, 1)
    }

    func testAutoCollapseWhenDroppingToOneEntry() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        m.addCompletion(message: "b", kind: .completed, detail: nil, at: t1)
        m.setExpanded(true)
        XCTAssertTrue(m.expanded)
        _ = m.removeCompletion(index: 1)   // 2 -> 1
        XCTAssertFalse(m.expanded, "2->1 removal must auto-collapse")
    }

    func testKeepsExpandedWhenDroppingThreeToTwo() {
        let m = CardModel()
        (0..<3).forEach { m.addCompletion(message: "m\($0)", kind: .completed, detail: nil, at: t0) }
        m.setExpanded(true)
        _ = m.removeCompletion(index: 1)   // 3 -> 2
        XCTAssertTrue(m.expanded, "3->2 removal must keep expanded")
        XCTAssertEqual(m.completionCount, 2)
    }

    func testDominantKindPriorityBlockedOverErrorOverCompleted() {
        let onlyCompleted = CardModel()
        onlyCompleted.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        XCTAssertEqual(onlyCompleted.dominantKind, .completed)

        let compAndError = CardModel()
        compAndError.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        compAndError.addCompletion(message: "b", kind: .error, detail: nil, at: t1)
        XCTAssertEqual(compAndError.dominantKind, .error)

        let allThree = CardModel()
        allThree.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        allThree.addCompletion(message: "b", kind: .error, detail: nil, at: t0)
        allThree.addCompletion(message: "c", kind: .blocked, detail: nil, at: t1)
        XCTAssertEqual(allThree.dominantKind, .blocked)
    }

    func testSummarySingleEntryWithoutDetail() {
        let m = CardModel()
        m.addCompletion(message: "任务已完成", kind: .completed, detail: nil, at: t0)
        XCTAssertEqual(m.summaryLine, "任务已完成")
    }

    func testSummarySingleEntryWithDetail() {
        let m = CardModel()
        m.addCompletion(message: "任务失败", kind: .error, detail: "ETIMEDOUT", at: t0)
        XCTAssertEqual(m.summaryLine, "任务失败 · ETIMEDOUT")
    }

    func testSummaryAllCompletedCountsWithNewestTime() {
        let m = CardModel()
        m.addCompletion(message: "任务已完成", kind: .completed, detail: nil, at: t0)
        m.addCompletion(message: "任务已完成", kind: .completed, detail: nil, at: t1)
        XCTAssertEqual(m.summaryLine, "已完成 2 次 · 最近 \(hhmm(t1))")
    }

    func testSummaryErrorMixReportsFailures() {
        let m = CardModel()
        m.addCompletion(message: "任务已完成", kind: .completed, detail: nil, at: t0)
        m.addCompletion(message: "任务已完成", kind: .completed, detail: nil, at: t0)
        m.addCompletion(message: "任务失败", kind: .error, detail: nil, at: t1)
        XCTAssertEqual(m.summaryLine, "3 次中 1 次失败 · 最近 \(hhmm(t1))")
    }

    func testSummaryBlockedOutranksErrorCopy() {
        let m = CardModel()
        m.addCompletion(message: "任务失败", kind: .error, detail: nil, at: t0)
        m.addCompletion(message: "需要你处理", kind: .blocked, detail: nil, at: t1)
        XCTAssertEqual(m.summaryLine, "2 次中 1 次需你处理 · 最近 \(hhmm(t1))")
    }

    func testContainsKind() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        m.addCompletion(message: "b", kind: .blocked, detail: nil, at: t1)
        XCTAssertTrue(m.contains(kind: .blocked))
        XCTAssertFalse(m.contains(kind: .error))
    }

    func testExpandControls() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: t0)
        XCTAssertFalse(m.expanded)
        m.setExpanded(true)
        XCTAssertTrue(m.expanded)
        m.setExpanded(true)   // no-op guard
        XCTAssertTrue(m.expanded)
        m.toggleExpanded()
        XCTAssertFalse(m.expanded)
    }
}
