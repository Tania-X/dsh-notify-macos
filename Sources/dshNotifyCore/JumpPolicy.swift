import Foundation

/// Static browser catalog + pure jump-decision helpers.
///
/// The app target's `BrowserJumper` owns the AppleScript/NSWorkspace side
/// effects; everything decision-shaped and side-effect-free lives here so it
/// can be unit-tested (probe ordering, retry policy, catalog data).
public enum BrowserCatalog {
    /// Browsers probed in order; the first one hosting the GUI tab wins.
    /// The names are what AppleScript resolves (stable across system
    /// languages); the bundle ids drive the running check (localizedName is
    /// localized, e.g. Safari -> "Safari浏览器" on a Chinese system).
    public static let candidates = [
        "Safari", "Google Chrome", "Microsoft Edge", "Brave Browser",
        "Arc", "Opera"
    ]

    /// Bundle identifiers (primary + common alternate channels) per candidate.
    public static let bundleIds: [String: [String]] = [
        "Safari": ["com.apple.Safari"],
        "Google Chrome": ["com.google.Chrome", "com.google.Chrome.canary"],
        "Microsoft Edge": ["com.microsoft.edgemac", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Beta"],
        "Brave Browser": ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.dev"],
        "Arc": ["company.thebrowser.Browser"],
        "Opera": ["com.operasoftware.Opera"]
    ]
}

/// Pure policy for the hosting-browser probe loop in BrowserJumper.jump.
public enum JumpPolicy {
    /// How many full passes over the running browsers before giving up.
    public static let maxProbePasses = 3
    /// Pause between passes that hit transient denials.
    public static let retryDelaySeconds: TimeInterval = 0.5

    /// Probe order with the last-successful browser moved to the front.
    public static func probeOrder(candidates: [String], preferring last: String?) -> [String] {
        var order = candidates
        if let last,
           let idx = order.firstIndex(of: last) {
            order.remove(at: idx)
            order.insert(last, at: 0)
        }
        return order
    }

    /// After one full pass over running browsers: retry only when at least
    /// one browser got DENIED (a transient -10004, e.g. a system dialog owns
    /// the focus) AND passes remain. A clean pass where every running browser
    /// reports no hosting tab needs no retry.
    public static func shouldRetry(afterPass pass: Int, sawDenied: Bool) -> Bool {
        sawDenied && pass < maxProbePasses
    }
}
