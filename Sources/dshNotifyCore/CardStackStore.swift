import Foundation

/// JSON file store for the card-stack snapshot.
///
/// Defensive by design: a missing or corrupt file simply yields an empty
/// snapshot (the daemon must never fail to start because of its cache).
public final class CardStackStore {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Why a load ended up empty (for logging / backups).
    public enum LoadDiagnostic: Equatable {
        case loaded(Int)
        case missing
        case unreadable
        case corrupt
        case versionMismatch(found: Int, expected: Int)
    }

    /// Read the snapshot together with the reason for the outcome, so callers
    /// can log and act (e.g. back up an incompatible file) instead of losing
    /// cards silently.
    public func loadWithDiagnostic() -> (snapshot: CardStackSnapshot, diagnostic: LoadDiagnostic) {
        guard let data = try? Data(contentsOf: url) else {
            return (CardStackSnapshot(), .missing)
        }
        guard let snapshot = try? decoder.decode(CardStackSnapshot.self, from: data) else {
            return (CardStackSnapshot(), .corrupt)
        }
        guard snapshot.version == CardStackSnapshot.currentVersion else {
            return (CardStackSnapshot(), .versionMismatch(
                found: snapshot.version, expected: CardStackSnapshot.currentVersion
            ))
        }
        return (snapshot, .loaded(snapshot.cards.count))
    }

    /// Read the snapshot; empty when absent, unreadable, or incompatible.
    public func load() -> CardStackSnapshot {
        loadWithDiagnostic().snapshot
    }

    /// Move an unusable snapshot aside instead of overwriting it later.
    public func backUp() {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    /// Write the snapshot atomically (no torn files on crash).
    public func save(_ snapshot: CardStackSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Remove the file (empty stack).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
