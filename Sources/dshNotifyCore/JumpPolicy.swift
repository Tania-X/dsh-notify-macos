import Foundation

/// One installable channel of a browser (what AppleScript needs to resolve it).
public struct BrowserChannel: Equatable {
    /// Name AppleScript can `tell application …` (channel-specific: e.g.
    /// "Microsoft Edge Dev" — `"Microsoft Edge"` fails to compile when only the
    /// Dev build is installed, which surfaced as an AppleScript -2740 error).
    public let appName: String
    public let bundleId: String

    public init(appName: String, bundleId: String) {
        self.appName = appName
        self.bundleId = bundleId
    }
}

/// A browser family (stable + channel builds), in preference order.
public struct BrowserFamily: Equatable {
    /// Stable family label (probe order / logs).
    public let key: String
    public let channels: [BrowserChannel]

    public init(key: String, channels: [BrowserChannel]) {
        self.key = key
        self.channels = channels
    }
}

/// Static browser catalog + pure resolution helpers.
///
/// The app target's `BrowserJumper` owns the AppleScript/NSWorkspace side
/// effects; everything decision-shaped and side-effect-free lives here so it
/// can be unit-tested (channel resolution, probe ordering, retry policy).
public enum BrowserCatalog {
    public static let families: [BrowserFamily] = [
        BrowserFamily(key: "Safari", channels: [
            BrowserChannel(appName: "Safari", bundleId: "com.apple.Safari"),
        ]),
        BrowserFamily(key: "Google Chrome", channels: [
            BrowserChannel(appName: "Google Chrome", bundleId: "com.google.Chrome"),
            BrowserChannel(appName: "Google Chrome Beta", bundleId: "com.google.Chrome.beta"),
            BrowserChannel(appName: "Google Chrome Canary", bundleId: "com.google.Chrome.canary"),
        ]),
        BrowserFamily(key: "Microsoft Edge", channels: [
            BrowserChannel(appName: "Microsoft Edge", bundleId: "com.microsoft.edgemac"),
            BrowserChannel(appName: "Microsoft Edge Beta", bundleId: "com.microsoft.edgemac.Beta"),
            BrowserChannel(appName: "Microsoft Edge Dev", bundleId: "com.microsoft.edgemac.Dev"),
            BrowserChannel(appName: "Microsoft Edge Canary", bundleId: "com.microsoft.edgemac.Canary"),
        ]),
        BrowserFamily(key: "Brave Browser", channels: [
            BrowserChannel(appName: "Brave Browser", bundleId: "com.brave.Browser"),
            BrowserChannel(appName: "Brave Browser Beta", bundleId: "com.brave.Browser.beta"),
            BrowserChannel(appName: "Brave Browser Dev", bundleId: "com.brave.Browser.dev"),
            BrowserChannel(appName: "Brave Browser Nightly", bundleId: "com.brave.Browser.nightly"),
        ]),
        BrowserFamily(key: "Arc", channels: [
            BrowserChannel(appName: "Arc", bundleId: "company.thebrowser.Browser"),
        ]),
        BrowserFamily(key: "Opera", channels: [
            BrowserChannel(appName: "Opera", bundleId: "com.operasoftware.Opera"),
        ]),
    ]

    /// The first channel of `family` that is running (channels are ordered
    /// most-stable-first, so a stable+Dev setup prefers the stable build).
    public static func runningChannel(
        for family: BrowserFamily, runningBundleIds: Set<String>
    ) -> BrowserChannel? {
        family.channels.first { runningBundleIds.contains($0.bundleId) }
    }

    /// Reverse lookup by AppleScript app name (for activation / last-used).
    public static func channel(appName: String) -> BrowserChannel? {
        for family in families {
            if let match = family.channels.first(where: { $0.appName == appName }) {
                return match
            }
        }
        return nil
    }

    /// Probe order for the browsers that are ACTUALLY running: families in
    /// catalog order, each resolved to its running channel's app name, with a
    /// previously successful app name moved to the front.
    public static func probeOrder(
        runningBundleIds: Set<String>, preferring last: String?
    ) -> [String] {
        var names: [String] = []
        for family in families {
            if let channel = runningChannel(for: family, runningBundleIds: runningBundleIds) {
                names.append(channel.appName)
            }
        }
        return JumpPolicy.probeOrder(candidates: names, preferring: last)
    }
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

    /// Whether the final fallback may `open` the deep link. Only a clean pass
    /// (browser reachable, but no tab hosts the GUI → the GUI is not open)
    /// justifies opening a URL: under a DENIED pass the browser is there but we
    /// are not allowed to drive it, and `open` would spawn a new tab and reload
    /// the GUI (the bug reported after a sandbox-started daemon).
    public static func shouldOpenFallback(sawDenied: Bool) -> Bool {
        !sawDenied
    }

    /// How long (seconds) to keep polling for "the browser actually came
    /// forward" after activation before declaring the jump unconfirmed.
    public static let activationSettleSeconds: Double = 0.75
    /// Polling step while waiting for the browser to become frontmost.
    public static let activationPollSeconds: Double = 0.05

    /// Whether to escalate from weak activation (keeps other Spaces' stacking
    /// intact) to `activateAllWindows`. A weak activation that did NOT make the
    /// browser frontmost means the hosting window never came into view — the
    /// reported "clicked the card, it vanished, nothing jumped" case — so
    /// raising the app's windows is worth the stacking trade-off.
    public static func shouldEscalateActivation(browserIsFrontmost: Bool) -> Bool {
        !browserIsFrontmost
    }

    /// Whether the user should actually SEE the jump: the tab was navigated AND
    /// its browser is frontmost (it may already have been frontmost — then no
    /// activation was needed and the tab switch is visible immediately).
    ///
    /// Callers keep the card/row when this is false, instead of dismissing it
    /// over a jump the user cannot see.
    public static func isVisibleToUser(navigated: Bool, browserIsFrontmost: Bool) -> Bool {
        navigated && browserIsFrontmost
    }
}

/// Deep-link construction for a card click (pure so it can be unit-tested).
public enum JumpLink {
    /// Hash namespace owned by the client half.
    public static let hashPrefix = "dsh-notify-macos/session="

    /// Build the URL the browser tab is pointed at. `turn` (when known) tells
    /// the client which turn's completion to scroll to; without it the client
    /// falls back to pinning the newest message.
    public static func url(base: String, sessionId: String, turn: Int? = nil) -> String {
        var hash = "\(hashPrefix)\(sessionId)"
        if let turn, turn > 0 { hash += "&turn=\(turn)" }
        return "\(base)/#\(hash)"
    }
}
