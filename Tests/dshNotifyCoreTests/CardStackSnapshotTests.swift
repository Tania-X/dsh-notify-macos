import XCTest
@testable import dshNotifyCore

final class CardStackSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testCompletionEntrySnapshotRoundTrip() {
        let entry = CompletionEntry(
            message: "任务失败", time: t0, kind: .error, detail: "ETIMEDOUT", index: 3
        )
        let restored = CompletionEntry(snapshot: entry.snapshot)
        XCTAssertEqual(restored.message, entry.message)
        XCTAssertEqual(restored.time, entry.time)
        XCTAssertEqual(restored.kind, entry.kind)
        XCTAssertEqual(restored.detail, entry.detail)
        XCTAssertEqual(restored.index, entry.index)
    }

    func testCompletionEntrySnapshotDegradesUnknownKind() {
        let snap = SnapshotEntry(message: "x", time: t0, kind: "weird", detail: nil, index: 1)
        XCTAssertEqual(CompletionEntry(snapshot: snap).kind, .completed)
    }

    func testCardModelRestoresEntriesAndExpandedState() {
        let entries = [
            CompletionEntry(message: "a", time: t0, kind: .completed, detail: nil, index: 1),
            CompletionEntry(message: "b", time: t0, kind: .blocked, detail: "tool", index: 2),
        ]
        let model = CardModel(entries: entries, expanded: true)
        XCTAssertEqual(model.completionCount, 2)
        XCTAssertEqual(model.entries.map(\.index), [1, 2])
        XCTAssertEqual(model.dominantKind, .blocked)
        XCTAssertTrue(model.expanded)
    }

    func testStoreRoundTripThroughFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-notify-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CardStackStore(url: url)

        let snapshot = CardStackSnapshot(cards: [
            SnapshotCard(
                sessionId: "session-1", sessionTitle: "T", action: "jump-web",
                path: nil, url: "http://127.0.0.1:3080", autoDismissSec: 30,
                deadline: t0.addingTimeInterval(30),
                expanded: true,
                entries: [
                    SnapshotEntry(message: "done", time: t0, kind: "completed", detail: nil, index: 1),
                    SnapshotEntry(message: "wait", time: t0, kind: "blocked", detail: "ask_user_question", index: 2),
                ]
            )
        ])
        store.save(snapshot)
        let loaded = store.load()
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.cards.first?.entries.map(\.kind), ["completed", "blocked"])
        XCTAssertEqual(loaded.cards.first?.expanded, true)
        XCTAssertEqual(loaded.cards.first?.deadline, t0.addingTimeInterval(30))
    }

    func testStoreYieldsEmptyOnMissingOrCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory
        let missing = dir.appendingPathComponent("dsh-notify-missing-\(UUID().uuidString).json")
        XCTAssertTrue(CardStackStore(url: missing).load().cards.isEmpty)

        let corrupt = dir.appendingPathComponent("dsh-notify-corrupt-\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        XCTAssertTrue(CardStackStore(url: corrupt).load().cards.isEmpty)
    }

    func testStoreIgnoresIncompatibleVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-notify-version-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let future = CardStackSnapshot(version: CardStackSnapshot.currentVersion + 1, cards: [
            SnapshotCard(
                sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
                autoDismissSec: nil, expanded: false,
                entries: [SnapshotEntry(message: "m", time: t0, kind: "completed", detail: nil, index: 1)]
            )
        ])
        CardStackStore(url: url).save(future)
        XCTAssertTrue(CardStackStore(url: url).load().cards.isEmpty)
    }

    func testStoreClearRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-notify-clear-\(UUID().uuidString).json")
        let store = CardStackStore(url: url)
        store.save(CardStackSnapshot(cards: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

    // MARK: auto-dismiss deadline (restart must not reset the countdown)

    private func card(autoDismissSec: Double?, deadline: Date?) -> SnapshotCard {
        SnapshotCard(
            sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
            autoDismissSec: autoDismissSec, deadline: deadline, expanded: false,
            entries: [SnapshotEntry(message: "m", time: t0, kind: "completed", detail: nil, index: 1)]
        )
    }

    func testExpiredDeadlineMeansCardIsNotRestored() {
        let expired = card(autoDismissSec: 5, deadline: t0)   // deadline long past
        XCTAssertTrue(expired.isExpired(at: t0.addingTimeInterval(1)))
        XCTAssertNil(expired.remainingAutoDismiss(at: t0.addingTimeInterval(1)))
    }

    func testLiveDeadlineResumesWithRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let live = card(autoDismissSec: 10, deadline: now.addingTimeInterval(4))
        XCTAssertFalse(live.isExpired(at: now))
        XCTAssertEqual(live.remainingAutoDismiss(at: now) ?? 0, 4, accuracy: 0.001)
    }

    func testLegacyCardWithoutDeadlineKeepsConfiguredSeconds() {
        let legacy = card(autoDismissSec: 3, deadline: nil)
        XCTAssertFalse(legacy.isExpired(at: t0))
        XCTAssertEqual(legacy.remainingAutoDismiss(at: t0), 3)
    }

    func testPermanentCardHasNoRemainingTimer() {
        let permanent = card(autoDismissSec: nil, deadline: nil)
        XCTAssertFalse(permanent.isExpired(at: t0))
        XCTAssertNil(permanent.remainingAutoDismiss(at: t0))
    }
}