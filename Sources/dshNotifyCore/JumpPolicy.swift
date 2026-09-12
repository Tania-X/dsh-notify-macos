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

    /// What a click's action achieved, as far as the daemon can tell.
    ///
    /// The distinction matters because the CALLER decides whether to drop the
    /// card: reporting a bare `Bool` invited "true" on paths that never checked
    /// anything (a card with no session id, `open-folder`/`open-web`), which
    /// dismissed the card over an action the user may never have seen — the very
    /// false-success this feature exists to prevent (AI review, severity 4).
    public enum JumpOutcome: Equatable {
        /// The action ran AND the user should see it (browser frontmost/raised).
        case visible
        /// Something was attempted but visibility could not be confirmed —
        /// keep the card/row so the click can be retried.
        case unconfirmed
        /// No confirmable jump is involved (folder reveal, plain URL open with
        /// no session to jump to): dismissing is the expected behaviour.
        case notApplicable
    }

    /// A window's frame, in screen coordinates (top-left origin), kept free of
    /// CoreGraphics so the matching rule stays unit-testable.
    public struct WindowBounds: Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Slack when matching a window reported by AppleScript against the
    /// on-screen window list: the two APIs do not always agree to the pixel
    /// (title-bar/shadow rounding), and an exact match would make us escalate
    /// for nothing.
    public static let windowBoundsTolerance: Double = 8

    /// Whether two window frames describe the same window.
    public static func boundsMatch(
        _ a: WindowBounds, _ b: WindowBounds, tolerance: Double = windowBoundsTolerance
    ) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Whether the window with `host` bounds is among the windows the system
    /// currently reports ON SCREEN — i.e. it is on the user's active Space, not
    /// minimized, not hidden.
    ///
    /// This is the window-level truth the app-level "is the browser frontmost"
    /// check was missing: with two browser windows on two Spaces, activating the
    /// app shows the CURRENT Space's window, so the hosting window can stay
    /// invisible while the app is perfectly frontmost (reported by the user:
    /// "it jumps, but it brings up the Safari on the current desktop").
    public static func isWindowOnScreen(
        _ host: WindowBounds, among onScreen: [WindowBounds]
    ) -> Bool {
        onScreen.contains { boundsMatch(host, $0) }
    }

    /// Whether the card/row may be dropped after an action with this outcome.
    /// Only `unconfirmed` keeps it — `visible` is done, `notApplicable` was
    /// never about a jump.
    public static func shouldDismissCard(after outcome: JumpOutcome) -> Bool {
        outcome != .unconfirmed
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
