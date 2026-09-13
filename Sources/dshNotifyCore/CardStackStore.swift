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

    /// Write the snapshot atomically (no torn files on crash) **and already private**.
    ///
    /// 快照里有会话标题/路径，所以必须 0600 —— 但**不能先写完再 chmod**：
    /// `Data.write(options: .atomic)` 是「写临时文件 → rename」，临时文件按进程 umask
    /// 创建，于是存在一段可读窗口（改之前实测 rename 之后文件就是 0644，窗口是实锤），
    /// 而且进程若在这两步之间被杀，文件会**永久**停在 0644。
    ///
    /// 做法：自己用 0600 建同目录临时文件，再 rename 覆盖 —— 权限从一出生就是对的。
    /// rename 在同一文件系统上是原子的（不会出现半个文件）；代价是从「原子替换」变成
    /// 「先删后改名」，中间有极短的无文件窗口 —— 读侧本来就把「缺文件」当空快照。
    public func save(_ snapshot: CardStackSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        let manager = FileManager.default
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: scratch.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        do {
            try? manager.removeItem(at: url)
            try manager.moveItem(at: scratch, to: url)
        } catch {
            try? manager.removeItem(at: scratch)   // 不留垃圾，也不动既有快照
        }
    }

    /// Remove the file (empty stack).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
