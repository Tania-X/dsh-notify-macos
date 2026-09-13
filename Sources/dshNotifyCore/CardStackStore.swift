import Darwin
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
    /// 做法：自己用 0600 建同目录临时文件，再用 POSIX `rename(2)` **原子覆盖**目标 ——
    /// 权限从一出生就是对的，不会出现半个文件，也不会丢既有快照。
    ///
    /// 为什么不用 `FileManager.moveItem`：目标存在时它会失败，于是得"先删再改名"，
    /// 中间那段窗口里旧快照已删、新快照未就位 —— `moveItem` 再失败就**彻底丢快照**
    /// （评审指出这点是对的；原实现 `Data.write(options: .atomic)` 反而不会丢）。
    /// `rename` 没有这个问题：覆盖是原子的，失败时旧文件完好。
    public func save(_ snapshot: CardStackSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        let manager = FileManager.default
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: scratch.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        if rename(scratch.path, url.path) != 0 {
            // 覆盖失败：清掉本次临时文件，**既有快照原样保留**（宁可旧也不要没有）。
            try? manager.removeItem(at: scratch)
        }
    }

    /// Remove the file (empty stack).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
