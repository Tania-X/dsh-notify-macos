import Foundation

/// Aggregated-card state machine: ONE session that completed N times.
///
/// Pure model extracted from the AppKit `NotificationCard` (see
/// docs/l2-swiftpm-split.md): multiple completions of the same session merge
/// into a single card (collapsed by default once N >= 2); expanding reveals
/// per-completion rows. No AppKit here — the window shell composes this and
/// owns frames/animations.
public final class CardModel {
    /// Completions in arrival order (last = newest). Always >= 1 in use.
    public private(set) var entries: [CompletionEntry] = []
    /// Whether the detail rows are shown (only meaningful when count > 1).
    public private(set) var expanded = false

    public init() {}

    /// Rebuild from persisted state (daemon restart / crash recovery).
    /// Entries are kept as given; the UI shell recreates the rows in order.
    public init(entries: [CompletionEntry], expanded: Bool) {
        self.entries = entries
        self.expanded = expanded
    }

    // MARK: Queries

    public var completionCount: Int { entries.count }
    public var newestEntry: CompletionEntry? { entries.last }
    public var isCollapsed: Bool { !expanded }

    /// Jump anchor for one row (1-based). Every completion keeps its OWN turn,
    /// so the rows of an aggregated card each land on their own position; a row
    /// without one falls back to `cardTurn` (the card's newest completion).
    /// Out-of-range rows (header click / empty card) also fall back.
    public func jumpTurn(forRow row: Int?, cardTurn: Int?) -> Int? {
        guard let row, row >= 1, row <= entries.count else { return cardTurn }
        return entries[row - 1].turn ?? cardTurn
    }

    /// Whether the card contains any entry of the given kind.
    public func contains(kind: OutcomeKind) -> Bool {
        entries.contains { $0.kind == kind }
    }

    /// The card's dominant kind = the HIGHEST-priority kind present
    /// (blocked > error > completed). The header accent follows this, so a
    /// card with any failure/attention item is never shown as plain green.
    public var dominantKind: OutcomeKind {
        if contains(kind: .blocked) { return .blocked }
        if contains(kind: .error) { return .error }
        return .completed
    }

    /// Body copy under the title, reflecting the card's composition:
    ///   single            -> the entry's message (plus detail when present)
    ///   all completed     -> "已完成 N 次 · 最近 hh:mm"
    ///   has error(s)      -> "N 次中 M 次失败 · 最近 hh:mm"
    ///   has blocked       -> "N 次中 B 次需你处理 · 最近 hh:mm" (blocked wins copy)
    public var summaryLine: String {
        guard let newest = newestEntry else { return "" }
        if entries.count == 1 {
            if let detail = newest.detail, !detail.isEmpty {
                return "\(newest.message) · \(detail)"
            }
            return newest.message
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: newest.time)
        let errorCount = entries.filter { $0.kind == .error }.count
        let blockedCount = entries.filter { $0.kind == .blocked }.count
        if blockedCount > 0 {
            return "\(entries.count) 次中 \(blockedCount) 次需你处理 · 最近 \(time)"
        }
        if errorCount > 0 {
            return "\(entries.count) 次中 \(errorCount) 次失败 · 最近 \(time)"
        }
        return "已完成 \(entries.count) 次 · 最近 \(time)"
    }

    // MARK: Mutations

    /// Append one completion. Recomputes nothing UI-related; returns the new
    /// entry index (1-based).
    @discardableResult
    public func addCompletion(
        message: String, kind: OutcomeKind, detail: String?, at time: Date = Date(), turn: Int? = nil
    ) -> Int {
        entries.append(
            CompletionEntry(
                message: message, time: time, kind: kind, detail: detail,
                index: entries.count + 1, turn: turn
            )
        )
        return entries.count
    }

    /// 1-based index of the row matching `entry` (same message/kind/time), or
    /// nil when it is no longer present.
    ///
    /// Row removal runs from an async click callback, so an index captured at
    /// click time can be stale by then (another click's removal already shifted
    /// the array). Removing by identity deletes the row the user actually
    /// clicked instead of a neighbour.
    public func index(of entry: CompletionEntry) -> Int? {
        entries.firstIndex {
            $0.time == entry.time && $0.message == entry.message && $0.kind == entry.kind
                && $0.detail == entry.detail && $0.turn == entry.turn
        }.map { $0 + 1 }
    }

    /// Remove the row matching `entry`; nil when it is already gone.
    @discardableResult
    public func removeCompletion(matching entry: CompletionEntry) -> CompletionEntry? {
        guard let index = index(of: entry) else { return nil }
        return removeCompletion(index: index)
    }

    /// Remove one completion by its 1-based arrival index and reindex the
    /// remainder so row indices stay contiguous. Auto-collapses when one or
    /// zero entries remain. Returns the removed entry, or nil when out of range.
    @discardableResult
    public func removeCompletion(index: Int) -> CompletionEntry? {
        guard index >= 1, index <= entries.count else { return nil }
        let removed = entries.remove(at: index - 1)
        for (i, entry) in entries.enumerated() {
            entries[i] = CompletionEntry(
                message: entry.message, time: entry.time,
                kind: entry.kind, detail: entry.detail, index: i + 1, turn: entry.turn
            )
        }
        if entries.count <= 1 { expanded = false }  // auto-collapse to single
        return removed
    }

    // MARK: Expand / collapse

    public func toggleExpanded() {
        expanded.toggle()
    }

    public func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
    }
}
