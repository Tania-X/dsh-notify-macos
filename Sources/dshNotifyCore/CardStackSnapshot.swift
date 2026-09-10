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

    public init(message: String, time: Date, kind: String, detail: String?, index: Int) {
        self.message = message
        self.time = time
        self.kind = kind
        self.detail = detail
        self.index = index
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
    public var expanded: Bool
    public var entries: [SnapshotEntry]

    public init(
        sessionId: String?, sessionTitle: String, action: String, path: String?,
        url: String?, autoDismissSec: Double?, expanded: Bool, entries: [SnapshotEntry]
    ) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.action = action
        self.path = path
        self.url = url
        self.autoDismissSec = autoDismissSec
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
        SnapshotEntry(message: message, time: time, kind: kind.rawValue, detail: detail, index: index)
    }

    /// Rebuild from a persisted entry (unknown kind degrades to completed).
    init(snapshot: SnapshotEntry) {
        self.init(
            message: snapshot.message,
            time: snapshot.time,
            kind: OutcomeKind.parse(snapshot.kind),
            detail: snapshot.detail,
            index: snapshot.index
        )
    }
}
