import Foundation

/// One completion occurrence inside an aggregated session card.
public struct CompletionEntry {
    public let message: String
    public let time: Date
    public let kind: OutcomeKind
    /// Structured detail (error message / tool name) when present.
    public let detail: String?
    /// Sequential index within the card (1-based, newest = last).
    public let index: Int

    public init(message: String, time: Date, kind: OutcomeKind, detail: String?, index: Int) {
        self.message = message
        self.time = time
        self.kind = kind
        self.detail = detail
        self.index = index
    }
}
