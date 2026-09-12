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

final class JumpLinkTests: XCTestCase {
    func testURLWithoutTurnKeepsPlainSessionHash() {
        XCTAssertEqual(
            JumpLink.url(base: "http://127.0.0.1:3080", sessionId: "session-1"),
            "http://127.0.0.1:3080/#dsh-notify-macos/session=session-1"
        )
    }

    func testURLWithTurnCarriesTheAnchor() {
        XCTAssertEqual(
            JumpLink.url(base: "http://127.0.0.1:3080", sessionId: "session-1", turn: 42),
            "http://127.0.0.1:3080/#dsh-notify-macos/session=session-1&turn=42"
        )
    }

    func testNonPositiveTurnIsDropped() {
        XCTAssertEqual(
            JumpLink.url(base: "http://127.0.0.1:3080", sessionId: "s", turn: 0),
            "http://127.0.0.1:3080/#dsh-notify-macos/session=s"
        )
    }
}

final class SnapshotTurnTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testTurnSurvivesSnapshotRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-notify-turn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CardStackStore(url: url)
        let card = SnapshotCard(
            sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
            autoDismissSec: nil, turn: 91, expanded: false,
            entries: [SnapshotEntry(message: "m", time: Date(timeIntervalSince1970: 1), kind: "completed", detail: nil, index: 1)]
        )
        store.save(CardStackSnapshot(cards: [card]))
        XCTAssertEqual(store.load().cards.first?.turn, 91)
    }

    /// Rows of an aggregated card keep their individual anchors across a
    /// daemon restart (the file is the only memory the daemon has).
    func testPerRowTurnsSurviveSnapshotRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-notify-rowturn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CardStackStore(url: url)
        let card = SnapshotCard(
            sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
            autoDismissSec: nil, turn: 93, expanded: true,
            entries: [
                SnapshotEntry(message: "a", time: Date(timeIntervalSince1970: 1), kind: "completed", detail: nil, index: 1, turn: 93),
                SnapshotEntry(message: "b", time: Date(timeIntervalSince1970: 2), kind: "completed", detail: nil, index: 2, turn: 61),
                SnapshotEntry(message: "c", time: Date(timeIntervalSince1970: 3), kind: "completed", detail: nil, index: 3),
            ]
        )
        store.save(CardStackSnapshot(cards: [card]))
        let loaded = store.load().cards.first
        XCTAssertEqual(loaded?.entries.map(\.turn), [93, 61, nil])
        XCTAssertEqual(loaded?.entries.map { CompletionEntry(snapshot: $0).turn }, [93, 61, nil])
    }

    /// Snapshot files written before per-row anchors existed (no `turn` key on
    /// entries) must still load — otherwise an upgrade wipes live cards.
    ///
    /// The legacy file is derived from a real snapshot with the per-row `turn`
    /// keys stripped, instead of being hand-written: the store decodes dates as
    /// **ISO8601 strings** (`"time": "2023-11-14T22:13:20Z"`), so a hand-rolled
    /// fixture drifts from the format and reports `.corrupt` for the wrong
    /// reason.
    func testLegacySnapshotWithoutPerRowTurnLoads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-notify-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CardStackStore(url: url)
        store.save(CardStackSnapshot(cards: [
            SnapshotCard(
                sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
                autoDismissSec: nil, turn: 93, expanded: false,
                entries: [
                    SnapshotEntry(
                        message: "a", time: t0, kind: "completed", detail: nil,
                        index: 1, turn: 93
                    )
                ]
            )
        ]))

        // Rewrite the file the way a pre-per-row-anchor daemon would have: the
        // card keeps its anchor, the entries have no `turn` at all.
        let data = try Data(contentsOf: url)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var cards = try XCTUnwrap(root["cards"] as? [[String: Any]])
        var card = cards[0]
        var entries = try XCTUnwrap(card["entries"] as? [[String: Any]])
        XCTAssertNotNil(entries[0].removeValue(forKey: "turn"), "fixture must actually drop the key")
        // `ref` (blocked-row correlation key) is newer still: strip it too so
        // the fixture stays a real pre-upgrade file.
        entries[0].removeValue(forKey: "ref")
        card["entries"] = entries
        cards[0] = card
        root["cards"] = cards
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        let (snapshot, diagnostic) = store.loadWithDiagnostic()
        guard case .loaded(let count) = diagnostic else {
            return XCTFail("legacy snapshot should load, got \(diagnostic)")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(snapshot.cards.first?.turn, 93)
        XCTAssertEqual(snapshot.cards.first?.entries.first?.message, "a")
        XCTAssertEqual(snapshot.cards.first?.entries.first?.time, t0)
        XCTAssertNil(snapshot.cards.first?.entries.first?.turn)
        XCTAssertNil(snapshot.cards.first?.entries.first?.ref)
    }
}