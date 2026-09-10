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

    /// Read the snapshot; empty when absent, unreadable, or from an
    /// incompatible version.
    public func load() -> CardStackSnapshot {
        guard let data = try? Data(contentsOf: url) else { return CardStackSnapshot() }
        guard let snapshot = try? decoder.decode(CardStackSnapshot.self, from: data) else {
            return CardStackSnapshot()
        }
        guard snapshot.version == CardStackSnapshot.currentVersion else {
            return CardStackSnapshot()
        }
        return snapshot
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
