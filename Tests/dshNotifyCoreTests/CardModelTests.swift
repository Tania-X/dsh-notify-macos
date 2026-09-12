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

/// Position-indexed jumps: every completion keeps its OWN turn anchor, so the
/// rows of an aggregated card each land on their own position instead of all
/// sharing the newest one.
final class PerRowTurnTests: XCTestCase {
    func testEachCompletionKeepsItsOwnTurn() {
        let m = CardModel()
        m.addCompletion(message: "newest", kind: .completed, detail: nil, turn: 93)
        m.addCompletion(message: "middle", kind: .completed, detail: nil, turn: 88)
        m.addCompletion(message: "oldest", kind: .completed, detail: nil, turn: 61)
        XCTAssertEqual(m.entries.map(\.turn), [93, 88, 61])
    }

    func testCompletionsWithoutTurnStayNil() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil)
        XCTAssertNil(m.entries.first?.turn)
    }

    func testRemoveCompletionReindexesWithoutLosingAnchors() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, turn: 10)
        m.addCompletion(message: "b", kind: .completed, detail: nil, turn: 20)
        m.addCompletion(message: "c", kind: .completed, detail: nil, turn: 30)
        XCTAssertNotNil(m.removeCompletion(index: 1))
        XCTAssertEqual(m.entries.map(\.index), [1, 2])
        XCTAssertEqual(m.entries.map(\.turn), [20, 30])
        XCTAssertEqual(m.entries.map(\.message), ["b", "c"])
    }

    func testJumpTurnUsesTheClickedRowsOwnAnchor() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil, turn: 10)
        m.addCompletion(message: "b", kind: .completed, detail: nil, turn: 20)
        // Two rows, two anchors — the whole point of position-indexed jumps.
        XCTAssertEqual(m.jumpTurn(forRow: 1, cardTurn: 20), 10)
        XCTAssertEqual(m.jumpTurn(forRow: 2, cardTurn: 20), 20)
    }

    func testRemoveCompletionByIdentitySurvivesAnEarlierRemoval() {
        let m = CardModel()
        let a = Date(timeIntervalSince1970: 1_700_000_000)
        let b = Date(timeIntervalSince1970: 1_700_000_060)
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: a, turn: 104)
        m.addCompletion(message: "b", kind: .completed, detail: nil, at: b, turn: 98)
        m.addCompletion(message: "c", kind: .completed, detail: nil, at: b, turn: 60)
        let clicked = m.entries[2]                       // row 3 = "c"
        XCTAssertNotNil(m.removeCompletion(index: 1))    // "a" was handled first
        XCTAssertEqual(m.index(of: clicked), 2)          // "c" shifted 3 -> 2
        XCTAssertEqual(m.removeCompletion(matching: clicked)?.message, "c")
        XCTAssertEqual(m.entries.map(\.message), ["b"])
    }

    func testIdenticalRowsStayDistinguishableByDetailAndTurn() {
        let m = CardModel()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        m.addCompletion(message: "same", kind: .error, detail: "E1", at: t, turn: 60)
        m.addCompletion(message: "same", kind: .error, detail: "E2", at: t, turn: 61)
        let second = m.entries[1]
        XCTAssertEqual(m.index(of: second), 2)
        _ = m.removeCompletion(index: 1)
        XCTAssertEqual(m.removeCompletion(matching: second)?.detail, "E2")
    }

    func testRemoveCompletionByMissingIdentityIsANoOp() {
        let m = CardModel()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        m.addCompletion(message: "a", kind: .completed, detail: nil, at: t, turn: 1)
        let gone = CompletionEntry(
            message: "ghost", time: t, kind: .completed, detail: nil, index: 9
        )
        XCTAssertNil(m.index(of: gone))
        XCTAssertNil(m.removeCompletion(matching: gone))
        XCTAssertEqual(m.completionCount, 1)
    }

    func testJumpTurnFallsBackToCardTurn() {
        let m = CardModel()
        m.addCompletion(message: "a", kind: .completed, detail: nil)   // no anchor
        m.addCompletion(message: "b", kind: .completed, detail: nil, turn: 20)
        XCTAssertEqual(m.jumpTurn(forRow: 1, cardTurn: 20), 20)        // row has none
        XCTAssertEqual(m.jumpTurn(forRow: nil, cardTurn: 20), 20)      // header/blank
        XCTAssertEqual(m.jumpTurn(forRow: 9, cardTurn: 20), 20)        // out of range
        XCTAssertNil(m.jumpTurn(forRow: 1, cardTurn: nil))             // nothing anywhere
    }
}
