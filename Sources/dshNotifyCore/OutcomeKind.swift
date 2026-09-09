/// Outcome kind of one completion occurrence.
/// Pure model type (Foundation-free): UI colors are provided by an extension
/// in the app target (`OutcomeKind+Color.swift`) so this library stays
/// unit-testable without AppKit.
public enum OutcomeKind: String {
    case completed
    case error
    case blocked

    /// Parse a wire kind string; anything unknown degrades to completed.
    public static func parse(_ raw: String?) -> OutcomeKind {
        switch raw {
        case "error": return .error
        case "blocked": return .blocked
        default: return .completed
        }
    }
}
