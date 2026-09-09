import AppKit
import dshNotifyCore

/// UI colors for an outcome kind. Kept OUT of dshNotifyCore so the pure
/// model stays AppKit-free and unit-testable.
extension OutcomeKind {
    /// Left accent bar / status dot color (on the dark card).
    var color: NSColor {
        switch self {
        case .completed: return NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)   // soft green
        case .error:     return NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1)   // red
        case .blocked:   return NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.25, alpha: 1)   // amber
        }
    }

    /// Dimmed variant for the aggregated summary line.
    var dimColor: NSColor {
        color.withAlphaComponent(0.9)
    }
}
