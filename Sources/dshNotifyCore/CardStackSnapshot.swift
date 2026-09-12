import Foundation

/// On-disk snapshot of the card stack, so pending cards survive a daemon
/// restart/crash (the plugin's promise: a card stays until the user acts).
/// Pure Codable DTOs — the AppKit shell maps them to/from its card windows.

/// One completion entry inside a card.
public struct SnapshotEntry: Codable, Equatable {
    public var message: String
    public var time: Date
    /// `OutcomeKind.rawValue` ("completed" | "error" | "blocked").
    public var kind: String
    public var detail: String?
    public var index: Int
    /// Per-completion jump anchor (the turn it happened in).
    public var turn: Int?

    public init(
        message: String, time: Date, kind: String, detail: String?, index: Int, turn: Int? = nil
    ) {
        self.message = message
        self.time = time
        self.kind = kind
        self.detail = detail
        self.index = index
        self.turn = turn
    }
}

/// One aggregated card (one session).
public struct SnapshotCard: Codable, Equatable {
    public var sessionId: String?
    public var sessionTitle: String
    public var action: String
    public var path: String?
    public var url: String?
    public var autoDismissSec: Double?
    /// Turn whose completion this card points at (position-indexed jump); nil
    /// for cards created before the anchor existed or without turn info.
    public var turn: Int?
    /// Absolute auto-dismiss deadline (set when the card was first shown), so
    /// a restart cannot reset the countdown or resurrect an expired card.
    public var deadline: Date?
    public var expanded: Bool
    public var entries: [SnapshotEntry]

    public init(
        sessionId: String?, sessionTitle: String, action: String, path: String?,
        url: String?, autoDismissSec: Double?, turn: Int? = nil, deadline: Date? = nil,
        expanded: Bool, entries: [SnapshotEntry]
    ) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.action = action
        self.path = path
        self.url = url
        self.autoDismissSec = autoDismissSec
        self.turn = turn
        self.deadline = deadline
        self.expanded = expanded
        self.entries = entries
    }
}

/// Whole stack snapshot.
public struct CardStackSnapshot: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var cards: [SnapshotCard]

    public init(version: Int = CardStackSnapshot.currentVersion, cards: [SnapshotCard] = []) {
        self.version = version
        self.cards = cards
    }
}

public extension CompletionEntry {
    /// DTO form for persistence.
    var snapshot: SnapshotEntry {
        SnapshotEntry(
            message: message, time: time, kind: kind.rawValue, detail: detail,
            index: index, turn: turn
        )
    }

    /// Rebuild from a persisted entry (unknown kind degrades to completed).
    init(snapshot: SnapshotEntry) {
        self.init(
            message: snapshot.message,
            time: snapshot.time,
            kind: OutcomeKind.parse(snapshot.kind),
            detail: snapshot.detail,
            index: snapshot.index,
            turn: snapshot.turn
        )
    }
}

public extension SnapshotCard {
    /// True when the card had an auto-dismiss deadline that has already passed.
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return deadline <= now
    }

    /// Auto-dismiss seconds to re-arm after a restart: nil when the card is
    /// permanent or carries no deadline (legacy), the remaining time when it
    /// still has some, and nil when it already expired (caller skips the card).
    public func remainingAutoDismiss(at now: Date = Date()) -> Double? {
        guard let deadline else { return autoDismissSec }
        let remaining = deadline.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }
}
