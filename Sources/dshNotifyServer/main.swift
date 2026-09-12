// dsh-notify-server — persistent top-right floating notification daemon.
//
// Renders completion cards pinned to the top-right corner of the screen,
// each headed by the completing session's name and the DSH brand whale mark.
// A card stays until the user acts:
//   - drag it to the right  -> dismiss (clear) it
//   - click it              -> run the click action (e.g. jump the browser to
//                              the finished conversation) and dismiss it
// Multiple cards may be shown at once, stacked from the top-right corner.
//
// Protocol: one JSON object per line over a Unix domain socket.
//   {"cmd":"show","sessionId":"...","sessionTitle":"...","message":"...","action":"jump-web|open-folder|open-web|none","url":"http://...","sound":true,"autoDismissSec":0}
//   {"cmd":"ping"}   -> replies {"ok":true}
//   {"cmd":"probe"}  -> replies {"ok":true,"chrome":…,"safari":…}
//   {"cmd":"debug"}  -> runs a jump on demand (diagnostics), replies {"ok":true}
//
// Build:  swiftc -O dsh-notify-server.swift -o dsh-notify-server
// Run:    ./dsh-notify-server [socketPath]

import AppKit
import Darwin
import Foundation
import dshNotifyCore

// MARK: - Diagnostics

/// Append one diagnostic line to the daemon log.
func dshLog(_ line: String) {
    let path = "/tmp/dsh-notify-macos.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Socket plumbing

func fillSockaddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: Int8.self, capacity: capacity) { dst in
            _ = strncpy(dst, path, capacity - 1)
            dst[capacity - 1] = 0
        }
    }
    return addr
}

/// True if another daemon already holds the socket (we then exit quietly).
func daemonAlreadyRunning(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = fillSockaddr(path)
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return rc == 0
}

/// Aggregated card: represents ONE session that completed N times.
/// Multiple completions of the same session merge into a single card
/// (collapsed by default once N >= 2); expanding reveals per-completion
/// rows. Dragging the whole card right clears that session's group.
final class NotificationCard: NSObject {
    let sessionId: String?
    let sessionTitle: String
    let action: String
    let path: String?
    let url: String?
    let window: NSWindow
    let view: CardView
    let autoDismissSec: Double?
    /// Turn whose completion this card points at (position-indexed jump).
    /// Mutable: when another completion of the same session merges in, the card
    /// follows the newest one.
    var turn: Int?
    /// Absolute auto-dismiss deadline, persisted so a restart cannot reset it.
    let autoDismissDeadline: Date?

    /// Pure aggregation state machine (extracted to dshNotifyCore for tests).
    let model = CardModel()

    var onRemoved: ((NotificationCard) -> Void)?
    var onToggleExpanded: ((NotificationCard) -> Void)?
    private var removing = false

    /// True while the card is animating out. It stays in the stack until the
    /// animation ends, so anything running in that window (merging a new
    /// completion, re-stacking, persisting) must treat it as already gone:
    /// otherwise a notification is drawn on a window that is about to
    /// disappear, or a rowless card gets written to the snapshot.
    var isDismissing: Bool { removing }

    /// Card dimensions.
    static let width: CGFloat = 360
    static let headerHeight: CGFloat = 56
    static let rowHeight: CGFloat = 30
    static let collapsedHeight = headerHeight

    init(
        sessionId: String?, sessionTitle: String, action: String, path: String?, url: String?,
        autoDismissSec: Double? = nil, turn: Int? = nil, deadline: Date? = nil
    ) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.action = action
        self.path = path
        self.url = url
        self.autoDismissSec = autoDismissSec
        self.turn = turn
        // Restored cards keep their original absolute deadline (recomputing it
        // as now+remaining would drift a little on every restart and the drift
        // would be written back to disk).
        self.autoDismissDeadline = deadline ?? ((autoDismissSec ?? 0) > 0
            ? Date().addingTimeInterval(autoDismissSec ?? 0)
            : nil)
        let rect = NSRect(x: 0, y: 0, width: NotificationCard.width, height: NotificationCard.collapsedHeight)
        self.view = CardView(frame: rect)
        self.window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        self.view.card = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false
        window.contentView = view
        window.title = "dsh-notify \(sessionTitle)"
        // Schedule from the absolute deadline when we have one (a restored
        // card resumes with exactly the time it had left), else from the
        // configured seconds.
        let delay = autoDismissDeadline.map { $0.timeIntervalSinceNow } ?? (autoDismissSec ?? 0)
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.dismiss()
            }
        }
    }

    // MARK: Data (forwarded to the pure CardModel)

    var entries: [CompletionEntry] { model.entries }
    var completionCount: Int { model.completionCount }
    var newestEntry: CompletionEntry? { model.newestEntry }
    var isCollapsed: Bool { model.isCollapsed }
    var expanded: Bool { model.expanded }

    /// Whether the card contains any entry of the given kind.
    func contains(kind: OutcomeKind) -> Bool { model.contains(kind: kind) }

    /// The card's dominant kind = the HIGHEST-priority kind present
    /// (blocked > error > completed).
    var dominantKind: OutcomeKind { model.dominantKind }

    /// Body copy under the title (composition-aware), see CardModel.
    var summaryLine: String { model.summaryLine }

    /// Append one completion, merging into this card. Recomputes the frame
    /// for collapsed/expanded height. Returns the entry index (1-based).
    @discardableResult
    func addCompletion(
        message: String, kind: OutcomeKind, detail: String?, at time: Date = Date(),
        turn: Int? = nil, ref: String? = nil
    ) -> Int {
        let index = model.addCompletion(
            message: message, kind: kind, detail: detail, at: time, turn: turn, ref: ref
        )
        updateFrame()
        return index
    }

    /// Drop the row carrying this correlation key (the user resolved the
    /// pending approval/question in the GUI). Returns the removed entry, or nil
    /// when no row matches — e.g. the card was already handled by hand.
    @discardableResult
    func removeCompletion(ref: String) -> CompletionEntry? {
        let removed = model.removeCompletion(ref: ref)
        updateFrame()
        return removed
    }

    /// Jump anchor for one row: that completion's own turn, falling back to the
    /// card-level turn (newest completion) when the row has none.
    func jumpTurn(forRow row: Int?) -> Int? {
        model.jumpTurn(forRow: row, cardTurn: turn)
    }

    /// The completion behind a 1-based row (nil when out of range) — used to
    /// identify the clicked row across the async jump that follows a click.
    func entry(atRow row: Int?) -> CompletionEntry? {
        guard let row, row >= 1, row <= entries.count else { return nil }
        return entries[row - 1]
    }

    /// Remove one completion by its 1-based arrival index (state in the
    /// model; re-stacks here). Returns the removed entry, or nil.
    @discardableResult
    func removeCompletion(index: Int) -> CompletionEntry? {
        let removed = model.removeCompletion(index: index)
        updateFrame()
        return removed
    }

    /// Remove the row matching `entry` — identity-based, so an async click
    /// callback cannot delete the wrong row after another removal shifted the
    /// indices. Returns the removed entry, or nil when it is already gone.
    @discardableResult
    func removeCompletion(matching entry: CompletionEntry) -> CompletionEntry? {
        let removed = model.removeCompletion(matching: entry)
        updateFrame()
        return removed
    }

    // MARK: Expand / collapse (state lives in the model)

    func toggleExpanded() {
        model.toggleExpanded()
        updateFrame()
        onToggleExpanded?(self)
    }

    func setExpanded(_ value: Bool) {
        model.setExpanded(value)
        updateFrame()
        onToggleExpanded?(self)
    }

    /// Recompute the window frame for the current expanded state.
    func updateFrame() {
        let h = expanded
            ? NotificationCard.headerHeight + CGFloat(entries.count) * NotificationCard.rowHeight
            : NotificationCard.collapsedHeight
        var frame = window.frame
        // Anchor the TOP edge: height changes grow the card downward, never
        // upward out of the screen. (CardStack.relayout then re-stacks all
        // cards from the screen top.)
        let oldTop = frame.maxY
        frame.size = NSSize(width: NotificationCard.width, height: h)
        frame.origin.y = oldTop - h
        window.setFrame(frame, display: true)
        view.frame = NSRect(x: 0, y: 0, width: NotificationCard.width, height: h)
        view.needsDisplay = true
        // Let the stack re-position every card under the new height.
        onToggleExpanded?(self)
    }

    // MARK: Actions

    /// Perform the click action (jump to the completion location).
    ///
    /// Card clicks always deep-link to the card's session (blocked included:
    /// its pending approval/ask lives at that session's newest message). The
    /// `focusOnly` switch is retained solely for the socket `debug` command.
    /// Run the click action. The return value is the HONEST, checkable signal:
    /// "was the command handed off" — nothing more. We deliberately do not try
    /// to judge whether the user *saw* the result: that is not knowable from
    /// here (every heuristic we tried — app frontmost, window on screen — was
    /// defeatable), and the guessing is what made this feature complicated.
    /// Handing the jump to the browser plus raising its window is the whole job.
    func performAction(focusOnly: Bool = false, turn turnOverride: Int? = nil) -> Bool {
        switch action {
        case "open-folder":
            guard let path, !path.isEmpty else {
                dshLog("[action] open-folder without a path; treating as handled no-op\n")
                return true
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            return true
        case "open-web":
            guard let url, let parsed = URL(string: url) else {
                dshLog("[action] open-web without a usable URL; treating as handled no-op\n")
                return true
            }
            NSWorkspace.shared.open(parsed)
            return true
        case "jump-web":
            // Jump the browser to this completion's own position: an aggregated
            // card gives every row its own anchor, so row N scrolls to the turn
            // THAT completion happened in (card-wide `turn` is the newest).
            return BrowserJumper.jump(
                url: url, sessionId: sessionId, sessionTitle: sessionTitle,
                turn: turnOverride ?? turn, focusOnly: focusOnly
            )
        default:
            return true
        }
    }

    /// Dismiss: animate off to the right edge, then remove.
    func dismiss() {
        guard !removing else { return }
        removing = true
        guard let screen = window.screen else {
            removeNow()
            return
        }
        let target = NSPoint(x: screen.visibleFrame.maxX + 40, y: window.frame.origin.y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrameOrigin(target)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeNow()
        }
    }

    private func removeNow() {
        window.orderOut(nil)
        onRemoved?(self)
    }
}
/// Card surface: draws the aggregated card (header + optional detail rows)
/// and handles drag-right-to-dismiss plus click-to-jump and expand/collapse.
final class CardView: NSView {
    weak var card: NotificationCard?

    private var dragStart: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragged = false

    /// Where the header (jumpable) area ends, in view coords from top.
    private let headerHeight: CGFloat = NotificationCard.headerHeight
    /// Right-edge affordance button rect (expand / collapse).
    private var affordanceRect: NSRect = .zero

    override var isOpaque: Bool { false }

    /// The DeepSeek Harness whale mark (vector path, parsed once).
    private static let whaleSVGPath = "M48.8354 10.0479C48.3232 9.79199 48.1025 10.2798 47.8032 10.5278C47.7007 10.6079 47.6143 10.7119 47.5273 10.8076C46.7793 11.624 45.9048 12.1597 44.7622 12.0957C43.0923 12 41.666 12.5356 40.4058 13.8398C40.1377 12.2319 39.2476 11.272 37.8926 10.6558C37.1836 10.3359 36.4668 10.0156 35.9702 9.31982C35.6235 8.82373 35.5293 8.27197 35.356 7.72754C35.2456 7.3999 35.1353 7.06396 34.7651 7.00781C34.3633 6.94385 34.2056 7.2876 34.0479 7.57568C33.418 8.75195 33.1733 10.0479 33.1973 11.3599C33.2524 14.312 34.4736 16.6641 36.8999 18.3359C37.1758 18.5278 37.2466 18.7197 37.1597 19C36.9946 19.5757 36.7974 20.1357 36.624 20.7119C36.5137 21.0801 36.3486 21.1597 35.9624 21C34.6309 20.4321 33.481 19.5918 32.4644 18.5757C30.7393 16.8721 29.1792 14.9917 27.2334 13.52C26.7764 13.1758 26.3193 12.856 25.8467 12.5518C23.8618 10.584 26.1069 8.96777 26.627 8.77588C27.1704 8.57568 26.8159 7.8877 25.0591 7.896C23.3022 7.90381 21.6953 8.50391 19.647 9.30371C19.3477 9.42383 19.0322 9.51172 18.7095 9.58398C16.8501 9.22363 14.9199 9.14355 12.9033 9.37598C9.10596 9.80762 6.07275 11.6396 3.84326 14.7681C1.16455 18.5278 0.53418 22.7998 1.30664 27.2559C2.11768 31.9521 4.46582 35.8398 8.07373 38.8799C11.8159 42.0322 16.1255 43.5762 21.041 43.2803C24.0269 43.104 27.3516 42.6963 31.1016 39.4561C32.0469 39.936 33.0396 40.1279 34.686 40.272C35.9546 40.3921 37.1758 40.208 38.1211 40.0078C39.6021 39.688 39.4995 38.2881 38.9639 38.0322C34.623 35.9678 35.5762 36.8081 34.71 36.1279C36.9155 33.4639 40.2402 30.6958 41.54 21.728C41.6426 21.0161 41.5557 20.5679 41.54 19.9917C41.5322 19.6396 41.6108 19.5039 42.0049 19.4639C43.0923 19.3359 44.1479 19.0317 45.1167 18.4878C47.9292 16.9199 49.064 14.3438 49.3315 11.2559C49.3711 10.7837 49.3237 10.2959 48.8354 10.0479ZM24.3262 37.8398C20.1196 34.4639 18.0791 33.3521 17.2358 33.3999C16.4482 33.4482 16.5898 34.3682 16.7632 34.9678C16.9443 35.5601 17.1812 35.9683 17.5117 36.4878C17.7402 36.832 17.8979 37.3442 17.2832 37.728C15.9282 38.584 13.5728 37.4399 13.4624 37.3838C10.7207 35.7358 8.42822 33.5601 6.81348 30.584C5.25342 27.7197 4.34766 24.6479 4.19775 21.3677C4.1582 20.5757 4.38672 20.2959 5.15869 20.1519C6.17529 19.96 7.22314 19.9199 8.23926 20.0718C12.5327 20.7119 16.1885 22.6719 19.2529 25.7759C21.002 27.5439 22.3252 29.6558 23.6885 31.7202C25.1377 33.9121 26.6978 36 28.6831 37.7119C29.3843 38.312 29.9434 38.7681 30.479 39.104C28.8643 39.2881 26.1699 39.3281 24.3262 37.8398ZM26.3433 24.6001C26.3433 24.248 26.6191 23.9678 26.9658 23.9678C27.0444 23.9678 27.1152 23.9839 27.1782 24.0078C27.2651 24.04 27.3438 24.0879 27.4067 24.1602C27.5171 24.272 27.5801 24.4321 27.5801 24.6001C27.5801 24.9521 27.3042 25.2319 26.9575 25.2319C26.6108 25.2319 26.3433 24.9521 26.3433 24.6001ZM32.6064 27.8799C32.2046 28.0479 31.8027 28.1919 31.4165 28.208C30.8179 28.2397 30.1641 27.9922 29.8096 27.688C29.2583 27.2158 28.8643 26.9521 28.6987 26.1279C28.6279 25.7759 28.6675 25.2319 28.7305 24.9199C28.8721 24.248 28.7144 23.8159 28.2495 23.4238C27.8716 23.104 27.3911 23.0161 26.8633 23.0161C26.666 23.0161 26.4849 22.9277 26.3511 22.856C26.1304 22.7441 25.9492 22.4639 26.1226 22.1201C26.1777 22.0078 26.4458 21.7358 26.5088 21.688C27.2256 21.272 28.0527 21.4077 28.8169 21.7197C29.5259 22.0161 30.0615 22.5601 30.834 23.3281C31.6216 24.2559 31.7632 24.5117 32.2124 25.208C32.5669 25.752 32.8901 26.312 33.1104 26.9521C33.2446 27.3521 33.0713 27.6802 32.6064 27.8799Z"

    /// The whale mark parsed once (50x50 logical coords, Y flipped).
    private static let whaleMarkUnit: NSBezierPath = {
        let path = NSBezierPath()
        let pattern = #"([A-Za-z])([^A-Za-z]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = whaleSVGPath as NSString
        let matches = regex.matches(in: whaleSVGPath, range: NSRange(location: 0, length: ns.length))
        func moveTo(_ x: CGFloat, _ y: CGFloat) {
            path.move(to: NSPoint(x: x, y: 50 - y))
        }
        func curveTo(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            path.curve(to: NSPoint(x: x, y: 50 - y), controlPoint1: NSPoint(x: c1x, y: 50 - c1y), controlPoint2: NSPoint(x: c2x, y: 50 - c2y))
        }
        for match in matches {
            let cmd = ns.substring(with: match.range(at: 1))
            let numStr = ns.substring(with: match.range(at: 2))
            let numbers = numStr.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
                .compactMap { Double($0) }
            switch cmd {
            case "M":
                if numbers.count >= 2 { moveTo(CGFloat(numbers[0]), CGFloat(numbers[1])) }
            case "C":
                var i = 0
                while i + 5 < numbers.count {
                    curveTo(CGFloat(numbers[i]), CGFloat(numbers[i + 1]), CGFloat(numbers[i + 2]), CGFloat(numbers[i + 3]), CGFloat(numbers[i + 4]), CGFloat(numbers[i + 5]))
                    i += 6
                }
            case "Z":
                path.close()
            default:
                break
            }
        }
        return path
    }()

    static func whaleMarkPath(in rect: NSRect) -> NSBezierPath {
        let path = whaleMarkUnit.copy() as! NSBezierPath
        let scale = rect.width / 50.0
        var transform = AffineTransform.identity
        transform.translate(x: rect.minX, y: rect.minY)
        transform.scale(x: scale, y: scale)
        path.transform(using: transform)
        return path
    }

    /// Total height for a card with `count` entries and given expand state.
    static func heightFor(count: Int, expanded: Bool) -> CGFloat {
        if count <= 1 || !expanded { return NotificationCard.collapsedHeight }
        return NotificationCard.headerHeight + CGFloat(count) * NotificationCard.rowHeight
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let card else { return }
        let w = bounds.width

        // Panel background (rounded, translucent dark).
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.12, alpha: 0.95).setFill()
        panel.fill()

        // Left accent bar in the card's dominant outcome color.
        let accent = card.dominantKind.color
        let bar = NSBezierPath(roundedRect: NSRect(x: 3, y: 6, width: 3.5, height: bounds.height - 12), xRadius: 1.75, yRadius: 1.75)
        accent.setFill()
        bar.fill()

        let multi = card.completionCount > 1
        // Header occupies the TOP headerHeight points of the view (whether
        // collapsed or expanded); everything below it is detail rows.
        let headerTop = bounds.height  // header band from (height - headerHeight) .. height

        // Whale mark — vertically centred in the header band.
        let markSize: CGFloat = 22
        let markRect = NSRect(
            x: 14,
            y: headerTop - headerHeight + (headerHeight - markSize) / 2,
            width: markSize, height: markSize
        )
        NSColor(calibratedWhite: 1, alpha: 1).setFill()
        CardView.whaleMarkPath(in: markRect).fill()

        // Right affordance (expand ▾ / collapse ▴) only when aggregated.
        affordanceRect = .zero
        if multi {
            let btnW: CGFloat = 30
            affordanceRect = NSRect(
                x: w - btnW - 8,
                y: headerTop - headerHeight + (headerHeight - 22) / 2,
                width: btnW, height: 22
            )
            let glyph = card.expanded ? "▴" : "▾"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(calibratedWhite: 0.8, alpha: 1)
            ]
            let size = (glyph as NSString).size(withAttributes: attrs)
            (glyph as NSString).draw(
                at: NSPoint(x: affordanceRect.midX - size.width / 2, y: affordanceRect.midY - size.height / 2),
                withAttributes: attrs
            )
        }

        // Title (top line of the header) and summary (second line).
        let textRight = multi ? affordanceRect.minX - 6 : w - 12
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        (card.sessionTitle as NSString).draw(
            in: NSRect(x: 46, y: headerTop - 24, width: textRight - 50, height: 18),
            withAttributes: titleAttrs
        )
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
        ]
        (card.summaryLine as NSString).draw(
            in: NSRect(x: 46, y: headerTop - 40, width: textRight - 50, height: 16),
            withAttributes: subAttrs
        )

        // Expanded detail rows below the header band.
        if multi && card.expanded {
            let headerBottom = headerTop - headerHeight
            var yCursor = headerBottom - NotificationCard.rowHeight
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for entry in card.entries {
                let rowRect = NSRect(x: 0, y: yCursor, width: w, height: NotificationCard.rowHeight)
                // Separator above each row after the first.
                if entry.index > 1 {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: 46, y: rowRect.maxY + 0.5))
                    line.line(to: NSPoint(x: w - 12, y: rowRect.maxY + 0.5))
                    NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
                    line.lineWidth = 1
                    line.stroke()
                }
                // Per-row status dot (left of the message).
                let dotSize: CGFloat = 6
                let dot = NSBezierPath(ovalIn: NSRect(x: 24, y: rowRect.minY + (rowRect.height - dotSize) / 2, width: dotSize, height: dotSize))
                entry.kind.color.setFill()
                dot.fill()
                let rowAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)
                ]
                let rowText = entry.detail.map { "\(entry.message) · \($0)" } ?? entry.message
                (rowText as NSString).draw(
                    in: NSRect(x: 38, y: rowRect.minY + 7, width: w - 128, height: 16),
                    withAttributes: rowAttrs
                )
                let timeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)
                ]
                let timeText = formatter.string(from: entry.time) as NSString
                timeText.draw(
                    in: NSRect(x: w - 70, y: rowRect.minY + 7, width: 58, height: 16),
                    withAttributes: timeAttrs
                )
                yCursor -= NotificationCard.rowHeight
            }
        }
    }

    // MARK: Hit testing

    /// Map a click point to the detail row index (1-based) if it landed on an
    /// expanded row; returns nil for the header or collapsed state.
    private func rowIndex(at point: NSPoint) -> Int? {
        guard let card = card, card.expanded, card.completionCount > 1 else { return nil }
        let yFromTop = bounds.height - point.y
        guard yFromTop >= headerHeight else { return nil }
        let row = Int((yFromTop - headerHeight) / NotificationCard.rowHeight) + 1
        return (row >= 1 && row <= card.completionCount) ? row : nil
    }

    // MARK: Mouse handling

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragStartOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = dragStartOrigin, let window else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        if abs(dx) > 3 { dragged = true }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + (current.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let origin = dragStartOrigin, let window, let card else {
            return
        }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let point = convert(current, from: nil)

        if dragged && dx > 40 {
            // Drag right: clear this session's whole group.
            card.dismiss()
        } else if !dragged {
            if card.completionCount > 1 {
                // Aggregated card (>= 2): header click only toggles
                // expand/collapse; a detail row click jumps AND removes that
                // row — the card stays until every row is handled.
                if let row = rowIndex(at: point) {
                    jumpAndRemoveRow(card, row: row)
                } else {
                    card.toggleExpanded()
                }
            } else {
                // Single-completion card: click jumps + clears (as before).
                jumpAndDismiss(card)
            }
        } else {
            // Small accidental drag: spring back.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().setFrameOrigin(origin)
            }
        }
        dragStart = nil
        dragStartOrigin = nil
    }

    /// Run the card action (jump), then dismiss. Browser driving can block
    /// briefly, so dispatch off the main thread and clear immediately.
    ///
    /// Every click — including BLOCKED entries — deep-links to the card's own
    /// session (its approval/ask UI lives at that session's newest message).
    /// Focus-only would leave the GUI on whichever session is active (the
    /// "newest" one) and miss the pending session entirely.
    private func jumpAndDismiss(_ card: NotificationCard) {
        jump(card) { [weak card] driven in
            guard let card else { return }
            if driven {
                card.dismiss()
            } else {
                // The jump never reached a browser: keeping the card (instead of
                // dismissing it) is what stops "clicked it, it just vanished".
                dshLog("[cards] jump not delivered; card kept so it can be retried\n")
            }
        }
    }

    /// Jump to one row's completion, then remove that row. When the last row
    /// is removed the card dismisses itself (onRemoved → CardStack.remove).
    /// BLOCKED rows deep-link to their session like any other; removing the
    /// row just marks it handled.
    private func jumpAndRemoveRow(_ card: NotificationCard, row: Int) {
        // Capture the ROW IDENTITY, not its index: the callback runs after an
        // async browser jump, by which time another click may already have
        // removed a row and shifted the indices.
        guard let clicked = card.entry(atRow: row) else { return }
        jump(card, turn: card.jumpTurn(forRow: row)) { [weak card] driven in
            guard let card else { return }
            guard driven else {
                dshLog("[cards] jump not delivered; row \(row) kept so it can be retried\n")
                return
            }
            Self.removeRowAndRestack(card, matching: clicked)
        }
    }

    /// Remove the clicked row (by identity) and re-stack; removing the last row
    /// dismisses the card.
    private static func removeRowAndRestack(
        _ card: NotificationCard, matching entry: CompletionEntry
    ) {
        guard card.removeCompletion(matching: entry) != nil else {
            // Already handled by an overlapping click: nothing left to do.
            dshLog("[cards] clicked row already removed; nothing to do\n")
            return
        }
        if card.completionCount == 0 {
            // Last row handled: animate out (onRemoved → CardStack.remove).
            // No relayout here — the card is still in the stack until the
            // animation ends, and relayouting it mid-dismiss would yank it
            // back into the stack position.
            card.dismiss()
        } else {
            // Rows remain: re-stack under the new (shorter) frame.
            card.onToggleExpanded?(card)
        }
    }

    /// Dispatch the card action off the main thread, then report back ON THE
    /// MAIN THREAD whether the command was handed off (card removal keys off
    /// that answer). Browser driving and Apple Events can block for seconds, so
    /// it never runs on the main thread (where the click's mouseUp handler is).
    private func jump(
        _ card: NotificationCard, focusOnly: Bool = false, turn: Int? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let action = card.action
        let run = { card.performAction(focusOnly: focusOnly, turn: turn) }
        guard completion != nil || action == "jump-web" else {
            // Nothing to report: fire and forget (no waiting in this path).
            _ = run()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = run()
            DispatchQueue.main.async { completion?(outcome) }
        }
    }
}
// MARK: - Session deep link

/// Opens the DeepSeek Harness Web UI pointed at one session.
///
/// Two layers:
///  1. Client half (lib/client.js) owns navigation: it listens for a
///     `#dsh-notify-macos/session=<id>` hash and calls the GUI's native
///     `sessions.open(id)` — no reload, no DOM poking, no browser JS
///     permission. This is the part that actually switches the session.
///  2. This daemon only has to make the hosting browser tab reach that hash.
///     It enumerates browsers (Safari / Chromium family) via AppleScript,
///     finds the tab already showing the GUI URL — on ANY Space/desktop —
///     and navigates THAT tab to the hashed URL. Navigating an existing tab
///     (set URL / open location) needs only the macOS Automation grant the
///     user already approved; it does NOT need "Allow JavaScript from Apple
///     Events". When no browser hosts the GUI, it falls back to the system
///     `open` command (the GUI loads and the client half still handles the
///     hash on boot).
enum BrowserJumper {
    /// Default GUI origin (the running web server's actual port when known).
    static var guiBaseUrl: String = "http://127.0.0.1:3080"

    /// Browser that last hosted the GUI (retried first next time).
    /// Jumps run on a background queue (DispatchQueue.global) and several can
    /// overlap (rapid card clicks), so reads/writes are lock-protected.
    private static let lastHostingBrowserLock = NSLock()
    private static var _lastHostingBrowser: String?
    private static var lastHostingBrowser: String? {
        get {
            lastHostingBrowserLock.lock()
            defer { lastHostingBrowserLock.unlock() }
            return _lastHostingBrowser
        }
        set {
            lastHostingBrowserLock.lock()
            defer { lastHostingBrowserLock.unlock() }
            _lastHostingBrowser = newValue
        }
    }

    /// Bundle ids of every browser process currently running. The browser
    /// catalog (families + channels) lives in dshNotifyCore so tests can
    /// assert the channel resolution.
    private static func runningBundleIds() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    /// Escape a value as an AppleScript double-quoted string literal.
    private static func asString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Run osascript with a script; returns its exit code, stdout, stderr.
    ///
    /// Bounded: an Apple Events call can block indefinitely (observed when a
    /// sandboxed daemon sends an event the system neither allows nor refuses),
    /// which would freeze the whole jump. A killed probe reports `dsh-timeout`,
    /// which classify() treats as `denied`.
    @discardableResult
    private static func runOSAScript(
        _ script: String, label: String = "", timeout: TimeInterval = 5
    ) -> (code: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            var timedOut = false
            if process.isRunning {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            if timedOut {
                dshLog("[osascript\(label.isEmpty ? "" : " " + label)] timed out after \(Int(timeout))s; killing probe\n")
                return (124, "", "dsh-timeout")
            }
            let code = process.terminationStatus
            let errText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            let outText = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            if code != 0 || !errText.isEmpty {
                dshLog(
                    "[osascript\(label.isEmpty ? "" : " " + label)] exit=\(code) err=\(errText.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                )
            }
            return (code, outText, errText)
        } catch {
            dshLog("[osascript\(label.isEmpty ? "" : " " + label)] launch error: \(error)\n")
            return (1, "", String(describing: error))
        }
    }

    /// Outcome of one hosting-tab probe.
    private enum ProbeOutcome {
        case hosted  // tab found and the action (navigate / focus) ran
        case noHost  // browser ran but no tab shows the GUI — try next browser
        case denied  // Apple events denied (e.g. transient -10004) — retry
        case timedOut // the probe had to be killed — retrying rarely helps
    }

    /// Classify an osascript result: exit 0 = hosted; our own "dsh-no-tab"
    /// error = noHost; anything else (permission errors, etc.) = denied.
    private static func classify(
        _ result: (code: Int32, stdout: String, stderr: String)
    ) -> ProbeOutcome {
        if result.code == 0 { return .hosted }
        if result.stderr.contains("dsh-no-tab") { return .noHost }
        if result.stderr.contains("dsh-timeout") { return .timedOut }
        return .denied
    }

    /// Activate the browser app (modern API). Only used to SURFACE the browser
    /// when we are not allowed to drive it; the normal path raises the hosting
    /// window from inside the AppleScript, which is the only way to pull a
    /// window over from another Space.
    private static func activateApp(_ appName: String) -> Bool {
        guard let channel = BrowserCatalog.channel(appName: appName),
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == channel.bundleId
              })
        else { return false }
        return app.activate(options: [])
    }

    /// Bundle id of whatever app is frontmost right now (diagnostics only).
    private static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Focus the browser window/tab already showing `guiUrl` (no URL change —
    /// used for a card that is waiting on the user's approval/answer already
    /// on screen). Raises that tab's window inside the app, then activates the
    /// app through the modern API (no cross-Space window raise).
    private static func focusHostingTab(appName: String, guiUrl: String) -> ProbeOutcome {
        let script: String
        if appName == "Safari" {
            script = """
            tell application "Safari"
              set targetTab to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t starts with \(asString(guiUrl)) then
                    set targetTab to t
                    exit repeat
                  end if
                end repeat
                if targetTab is not missing value then exit repeat
              end repeat
              if targetTab is not missing value then
                set hostWindow to (first window whose tabs contains targetTab)
                if miniaturized of hostWindow then set miniaturized of hostWindow to false
                set current tab of hostWindow to targetTab
                set index of hostWindow to 1
                activate
              else
                error "dsh-no-tab"
              end if
            end tell
            """
        } else {
            // Chromium family: activate the hosting window/tab only.
            script = """
            tell application \(asString(appName))
              set targetTab to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t starts with \(asString(guiUrl)) then
                    set targetTab to t
                    exit repeat
                  end if
                end repeat
                if targetTab is not missing value then exit repeat
              end repeat
              if targetTab is not missing value then
                set hostWindow to (first window whose tabs contains targetTab)
                try
                  if miniaturized of hostWindow then set miniaturized of hostWindow to false
                end try
                set active tab index of hostWindow to (index of targetTab)
                set index of hostWindow to 1
                activate
              else
                error "dsh-no-tab"
              end if
            end tell
            """
        }
        let outcome = classify(runOSAScript(script, label: "focus-\(appName)"))
        if outcome == .hosted {
            dshLog("[focus] \(appName) hosting window raised (AppleScript activate)\n")
        }
        return outcome
    }

    /// Find and navigate the tab that already shows `guiUrl` to `targetURL`.
    /// Safari and Chromium use different dialects. Only tab enumeration +
    /// navigation — no `execute javascript` for Safari, so the browser-side
    /// "Allow JavaScript from Apple Events" setting is NOT required (macOS
    /// Automation permission alone suffices). Chromium targets the enumerated
    /// tab directly (never relies on the front window), then the app is
    /// activated through the modern API (no cross-Space window raise).
    private static func navigateHostingTab(
        appName: String, guiUrl: String, targetURL: String
    ) -> ProbeOutcome {
        let script: String
        if appName == "Safari" {
            // Safari can `set URL` on the specific tab directly.
            script = """
            tell application "Safari"
              set targetTab to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t starts with \(asString(guiUrl)) then
                    set targetTab to t
                    exit repeat
                  end if
                end repeat
                if targetTab is not missing value then exit repeat
              end repeat
              if targetTab is not missing value then
                set hostWindow to (first window whose tabs contains targetTab)
                if miniaturized of hostWindow then set miniaturized of hostWindow to false
                set URL of targetTab to \(asString(targetURL))
                set current tab of hostWindow to targetTab
                set index of hostWindow to 1
                activate
              else
                error "dsh-no-tab"
              end if
            end tell
            """
        } else {
            // Chromium: tab.URL is read-only; execute javascript on the
            // enumerated targetTab itself (needs "Allow JavaScript from Apple
            // Events"), falling back to `open location`.
            script = """
            tell application \(asString(appName))
              set targetTab to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t starts with \(asString(guiUrl)) then
                    set targetTab to t
                    exit repeat
                  end if
                end repeat
                if targetTab is not missing value then exit repeat
              end repeat
              if targetTab is missing value then error "dsh-no-tab"
              set hostWindow to (first window whose tabs contains targetTab)
              try
                if miniaturized of hostWindow then set miniaturized of hostWindow to false
              end try
              set active tab index of hostWindow to (index of targetTab)
              set index of hostWindow to 1
              activate
              try
                execute targetTab javascript \(asString("location.href = \(asString(targetURL));"))
              on error
                open location \(asString(targetURL))
              end try
            end tell
            """
        }
        let outcome = classify(runOSAScript(script, label: "navigate-\(appName)"))
        if outcome == .hosted {
            dshLog("[navigate] \(appName) tab updated; hosting window raised\n")
        }
        return outcome
    }

    /// Jump: point the hosting browser tab at the hashed GUI URL so the
    /// client half switches sessions in place; fall back to `open` when no
    /// browser hosts the GUI yet. When `focusOnly` is true (a card waiting on
    /// the user, e.g. approval/answer) it activates the hosting tab without
    /// navigating — the pending UI is already there.
    /// Hand the deep link to the browser hosting the GUI. Returns whether the
    /// command was DELIVERED — deliberately not a claim about what the user saw
    /// (see `performAction`).
    @discardableResult
    static func jump(
        url: String?, sessionId: String?, sessionTitle: String?, turn: Int? = nil,
        focusOnly: Bool = false
    ) -> Bool {
        dshLog("[jump] start focusOnly=\(focusOnly) url=\(url ?? "nil") sessionId=\(sessionId ?? "nil") title=\(sessionTitle ?? "nil")\n")
        let guiUrl = (url?.isEmpty == false) ? url! : guiBaseUrl
        guard let sessionId, !sessionId.isEmpty else {
            // Nothing to jump to: this only opens the GUI root. It is not a
            // position jump, so the card may be dismissed as before — but say
            // what actually happened instead of claiming a visible jump.
            if let parsed = URL(string: guiUrl) { NSWorkspace.shared.open(parsed) }
            dshLog("[jump] no sessionId: opened \(guiUrl) (not a position jump)\n")
            return true
        }
        let base = (url?.isEmpty == false) ? url! : guiBaseUrl
        let target = JumpLink.url(base: base, sessionId: sessionId, turn: turn)
        dshLog("[jump] target=\(target) (turn=\(turn.map(String.init) ?? "nil"))\n")

        // Running browsers only, each resolved to the app name AppleScript
        // can actually resolve for its channel (e.g. "Microsoft Edge Dev"),
        // with the browser that worked last time first.
        let running = runningBundleIds()
        let lastSuccessful = lastHostingBrowser
        let order = BrowserCatalog.probeOrder(runningBundleIds: running, preferring: lastSuccessful)
        if order.isEmpty {
            dshLog("[jump] probe order: [] (no catalogued browser is running)\n")
        } else {
            dshLog(
                "[jump] probe order: \(order.joined(separator: " > "))"
                + " (running=\(running.count) bundles, lastSuccessful=\(lastSuccessful ?? "nil"))\n"
            )
        }

        // A -10004 (Apple events denied while e.g. a system dialog owns the
        // focus) is transient: retry the whole probe up to 3 times, but only
        // while some running browser got DENIED. A clean pass where every
        // running browser reports no hosting tab needs no retry.
        var sawDeniedAnyPass = false
        var sawNoHostAnyPass = false
        for pass in 1...JumpPolicy.maxProbePasses {
            var sawDenied = false
            var sawTimeout = false
            for app in order {
                dshLog("[jump] pass \(pass) probing \(app)\n")
                let outcome: ProbeOutcome = focusOnly
                    ? focusHostingTab(appName: app, guiUrl: guiUrl)
                    : navigateHostingTab(appName: app, guiUrl: guiUrl, targetURL: target)
                switch outcome {
                case .hosted:
                    lastHostingBrowser = app
                    dshLog("[jump] \(focusOnly ? "focused" : "navigated") tab in \(app) (delivered)\n")
                    return true
                case .denied:
                    sawDenied = true   // transient? try the whole pass again
                    sawDeniedAnyPass = true
                case .timedOut:
                    // A hung probe means we could not talk to the browser at all
                    // (permission prompt, sandbox). Treat it as undrivable — so
                    // no `open` (that would spawn a new tab) — and don't burn the
                    // remaining passes retrying it.
                    dshLog("[jump] \(app) probe timed out; treating as undrivable\n")
                    sawDenied = true
                    sawDeniedAnyPass = true
                    sawTimeout = true
                case .noHost:
                    sawNoHostAnyPass = true   // try the next running browser
                }
            }
            if sawTimeout { break }        // a hung browser won't answer next pass
            if !sawDenied { break }
            if JumpPolicy.shouldRetry(afterPass: pass, sawDenied: sawDenied) {
                Thread.sleep(forTimeInterval: JumpPolicy.retryDelaySeconds)
            }
        }

        guard JumpPolicy.shouldOpenFallback(sawDenied: sawDeniedAnyPass) else {
            // A DENIED pass means the browser is running but we are not allowed
            // to drive it (macOS Automation denied — e.g. the daemon was started
            // from a sandboxed shell). `open` would spawn a NEW TAB and reload
            // the GUI, so don't: surface the browser through NSRunningApplication
            // (no Apple Events needed) and say why.
            dshLog("[jump] automation denied for a running browser; NOT opening a new tab\n")
            dshLog("[jump] hint: restart the daemon outside a sandbox (or let the plugin spawn it) and re-grant Automation\n")
            if let first = order.first {
                dshLog("[jump] surfaced \(first) instead (undrivable)\n")
                _ = activateApp(first)
            }
            return false
        }

        // Clean pass: browsers were reachable but no tab hosts the GUI, i.e. the
        // GUI is not open anywhere → opening the deep link is the right recovery.
        dshLog("[jump] no hosting tab found (noHost=\(sawNoHostAnyPass)); falling back to open\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [focusOnly ? guiUrl : target]
        do {
            try process.run()
            process.waitUntilExit()
            dshLog(
                "[jump] open exit=\(process.terminationStatus)"
                + " (frontmost=\(frontmostBundleId() ?? "nil"))\n"
            )
            // LaunchServices opens+activates the browser itself; the exit status
            // is the only thing we can honestly report here.
            return process.terminationStatus == 0
        } catch {
            dshLog("[jump] open failed: \(error)\n")
            return false
        }
    }
}

// MARK: - Card stack

/// Manages aggregated cards (one per session). New completions of a session
/// that already has a card merge into it instead of stacking another card.
final class CardStack {
    private var cards: [NotificationCard] = []
    private let margin: CGFloat = 12
    private let gap: CGFloat = 8
    /// Snapshot store so pending cards survive a daemon restart/crash.
    private let store: CardStackStore?
    /// True while rebuilding from disk (suppresses persist churn).
    private var restoring = false

    init(store: CardStackStore? = nil) {
        self.store = store
        restore()
    }

    /// Rebuild the cards from the on-disk snapshot.
    private func restore() {
        guard let store else { return }
        let (snapshot, diagnostic) = store.loadWithDiagnostic()
        switch diagnostic {
        case .loaded(let count):
            dshLog("[cards] snapshot loaded: \(count) card(s)\n")
        case .missing:
            break
        case .unreadable:
            dshLog("[cards] snapshot unreadable; starting empty\n")
        case .corrupt:
            dshLog("[cards] snapshot corrupt; backing up and starting empty\n")
            store.backUp()
        case .versionMismatch(let found, let expected):
            dshLog("[cards] snapshot version \(found) != \(expected); backing up and starting empty\n")
            store.backUp()
        }
        guard !snapshot.cards.isEmpty else { return }
        restoring = true
        // `defer` so a failure can never leave persistence disabled forever.
        defer { restoring = false }
        for sc in snapshot.cards {
            // Expired auto-dismiss cards stay gone; the rest resume with the
            // remaining time instead of a fresh full countdown.
            let now = Date()
            if sc.isExpired(at: now) {
                dshLog("[cards] skipping expired card \(sc.sessionTitle)\n")
                continue
            }
            guard !sc.entries.isEmpty else {
                // A row-less card has nothing to show or click; older builds
                // could persist one when a relayout happened mid-dismiss.
                dshLog("[cards] skipping empty card \(sc.sessionTitle)\n")
                continue
            }
            let card = NotificationCard(
                sessionId: sc.sessionId,
                sessionTitle: sc.sessionTitle,
                action: sc.action,
                path: sc.path,
                url: sc.url,
                autoDismissSec: sc.remainingAutoDismiss(at: now),
                turn: sc.turn,
                deadline: sc.deadline
            )
            for entry in sc.entries {
                card.addCompletion(
                    message: entry.message,
                    kind: OutcomeKind.parse(entry.kind),
                    detail: entry.detail,
                    at: entry.time,
                    turn: entry.turn,
                    ref: entry.ref
                )
            }
            card.onRemoved = { [weak self] removed in
                self?.remove(removed)
            }
            card.onToggleExpanded = { [weak self] _ in
                self?.relayout(animated: true)
            }
            cards.append(card)
            // Change the model directly: card.setExpanded() would fire the
            // UI callback (relayout per card) while the stack is half-built.
            if sc.expanded { card.model.setExpanded(true) }
        }
        // Give expanded cards their real height before the single relayout.
        for card in cards { card.updateFrame() }
        relayout(animated: false)
        if cards.isEmpty {
            // Every snapshot entry was expired: drop the stale file so it is
            // not re-read (and re-skipped) on the next start.
            store.clear()
            dshLog("[cards] all restored cards expired; snapshot cleared\n")
        }
        dshLog("[cards] restored \(cards.count) card(s) from \(store.url.path)\n")
    }

    /// Persist the current stack (no-op while restoring or without a store).
    private func persist() {
        guard let store, !restoring else { return }
        // A card that is dismissing is already gone as far as the user is
        // concerned; it is only still in `cards` so the animation can finish.
        // Persisting it recorded a rowless card that came back as a weird empty
        // card after a restart. Same reasoning as relayout skipping it.
        let live = cards.filter { !$0.isDismissing }
        guard !live.isEmpty else {
            // Nothing worth keeping: remove the file instead of an empty snapshot.
            store.clear()
            return
        }
        let snapshot = CardStackSnapshot(cards: live.map { card in
            SnapshotCard(
                sessionId: card.sessionId,
                sessionTitle: card.sessionTitle,
                action: card.action,
                path: card.path,
                url: card.url,
                autoDismissSec: card.autoDismissSec,
                turn: card.turn,
                deadline: card.autoDismissDeadline,
                expanded: card.expanded,
                entries: card.entries.map(\.snapshot)
            )
        })
        store.save(snapshot)
    }

    /// Drop the row that waits on `ref` (the user resolved that approval or
    /// question in the GUI). When it was the card's last row the card dismisses
    /// itself; with rows left it re-stacks (and a one-row card auto-collapses,
    /// see CardModel.removeCompletion).
    ///
    /// Reply payload mirrors the smoke test's counting style so a client can
    /// assert the effect without reading the disk snapshot.
    func clear(sessionId: String, ref: String) -> String {
        guard let card = cards.first(where: { $0.sessionId == sessionId }) else {
            dshLog("[clear] no card for session \(sessionId) ref=\(ref); nothing to do\n")
            return "{\"ok\":true,\"removed\":0,\"reason\":\"no-card\"}"
        }
        guard card.removeCompletion(ref: ref) != nil else {
            dshLog("[clear] card for \(sessionId) has no row with ref=\(ref); nothing to do\n")
            return "{\"ok\":true,\"removed\":0,\"reason\":\"no-row\",\"remaining\":\(card.completionCount)}"
        }
        let remaining = card.completionCount
        dshLog("[clear] removed ref=\(ref); \(remaining) row(s) left\n")
        if remaining == 0 {
            // Last row was waiting on the user: the whole card goes away
            // (onRemoved → CardStack.remove, then relayout/persist).
            card.dismiss()
        } else {
            // Re-stack under the shorter frame; the model already collapsed a
            // single remaining row, so the card shows as collapsed.
            card.onToggleExpanded?(card)
        }
        return "{\"ok\":true,\"removed\":1,\"remaining\":\(remaining)}"
    }

    /// Diagnostic state (socket `state` command).
    func stateSummary() -> String {
        let entries = cards.reduce(0) { $0 + $1.completionCount }
        return "{\"ok\":true,\"cards\":\(cards.count),\"entries\":\(entries)}"
    }

    /// Show a completion. If a card for the same session already exists,
    /// merge into it (append entry, auto-expand optional); else create one.
    func show(request: ShowRequest) {
        // One line per delivered frame: makes the host→daemon contract visible
        // in the log (which kind, which session, and the blocked-row key that
        // lets a later `clear` find exactly this row).
        dshLog(
            "[show] kind=\(request.kind ?? "completed")"
            + " session=\(request.sessionId ?? "nil")"
            + " turn=\(request.turn.map(String.init) ?? "nil")"
            + " ref=\(request.ref ?? "nil")\n"
        )
        let sessionTitle: String
        if let st = request.sessionTitle, !st.isEmpty {
            sessionTitle = st
        } else if let t = request.title, !t.isEmpty {
            sessionTitle = t
        } else {
            sessionTitle = "DeepSeek Harness"
        }
        let message = request.message.flatMap { $0.isEmpty ? nil : $0 } ?? "任务已完成"
        let kind = OutcomeKind.parse(request.kind)
        let detail = request.detail
        let action = request.action ?? "jump-web"

        // Merge into an existing card for the same session — but never into one
        // that is already flying out: its window is mid-dismiss and will be gone
        // in a moment, so the merge would silently swallow the notification.
        if let sessionId = request.sessionId, !sessionId.isEmpty,
           let existing = cards.first(where: { $0.sessionId == sessionId && !$0.isDismissing }) {
            existing.addCompletion(
                message: message, kind: kind, detail: detail, turn: request.turn, ref: request.ref
            )
            if let turn = request.turn { existing.turn = turn }   // newest completion wins
            relayout(animated: false)
            if request.sound == true { NSSound(named: NSSound.Name("Glass"))?.play() }
            return
        }

        // No session id (legacy) or no existing card: create a new one.
        let card = NotificationCard(
            sessionId: request.sessionId,
            sessionTitle: sessionTitle,
            action: action,
            path: request.path,
            url: request.url,
            autoDismissSec: request.autoDismissSec,
            turn: request.turn
        )
        card.addCompletion(
            message: message, kind: kind, detail: detail, turn: request.turn, ref: request.ref
        )
        card.onRemoved = { [weak self] removed in
            self?.remove(removed)
        }
        card.onToggleExpanded = { [weak self] _ in
            self?.relayout(animated: true)
        }
        cards.append(card)
        relayout(animated: false)
        if request.sound == true { NSSound(named: NSSound.Name("Glass"))?.play() }
    }

    private func remove(_ card: NotificationCard) {
        cards.removeAll { $0 === card }
        relayout(animated: true)
    }

    private func relayout(animated: Bool) {
        defer { persist() }   // single hook: every structural change re-layouts
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.maxY - margin
        for card in cards {
            // A card that is dismissing must be left alone: it is still in the
            // stack (it only leaves when the animation finishes), and re-stacking
            // it here would yank it back to the top-right corner mid-flight —
            // the user would see it move out, snap back, then disappear.
            guard !card.isDismissing else { continue }
            let frame = card.window.frame
            let targetOrigin = NSPoint(x: screen.maxX - frame.width - margin, y: y - frame.height)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    card.window.animator().setFrameOrigin(targetOrigin)
                }
            } else {
                card.window.setFrameOrigin(targetOrigin)
                card.window.orderFrontRegardless()
            }
            y -= frame.height + gap
        }
    }
}
// MARK: - Socket server (background thread)

final class SocketServer {
    private let path: String
    private var fd: Int32 = -1
    private var running = true

    init(path: String) {
        self.path = path
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            listenLoop()
        }
    }

    func stop() {
        running = false
        if fd >= 0 { close(fd) }
    }

    private func listenLoop() {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("dsh-notify-server: socket() failed")
            return
        }
        var addr = fillSockaddr(path)
        let bindRc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRc == 0 else {
            print("dsh-notify-server: bind() failed (\(bindRc))")
            return
        }
        guard listen(fd, 16) == 0 else {
            print("dsh-notify-server: listen() failed")
            return
        }
        while running {
            let client = accept(fd, nil, nil)
            if client >= 0 {
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    handle(client: client)
                }
            }
        }
    }

    private func handle(client: Int32) {
        // Read the whole request in chunks, then respond. Each connection is
        // handled on its own background thread with a private fd, so there is
        // no shared state between connections. Retry on EINTR.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.contains(0x0A) { break }  // newline terminates a request
            } else if n == 0 {
                break  // EOF
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        var deferred = false
        if !buffer.isEmpty {
            deferred = processLine(buffer, replyTo: client)
        }
        if !deferred { close(client) }
    }

    /// Handle one request. Returns true when the reply is written
    /// asynchronously (the caller must then leave the fd open).
    @discardableResult
    private func processLine(_ data: Data, replyTo fd: Int32) -> Bool {
        // Write a reply (one JSON line) back to the client.
        func reply(_ text: String) {
            text.withCString { ptr in
                _ = Darwin.write(fd, ptr, text.utf8.count)
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let cmd = object["cmd"] as? String else { return false }
        switch cmd {
        case "show":
            let request = ShowRequest(
                cmd: "show",
                title: object["title"] as? String,
                message: object["message"] as? String,
                kind: object["kind"] as? String,
                detail: object["detail"] as? String,
                action: object["action"] as? String,
                path: object["path"] as? String,
                url: object["url"] as? String,
                sessionId: object["sessionId"] as? String,
                sessionTitle: object["sessionTitle"] as? String,
                sound: object["sound"] as? Bool,
                autoDismissSec: object["autoDismissSec"] as? Double,
                turn: object["turn"] as? Int,
                ref: object["ref"] as? String
            )
            DispatchQueue.main.async { [weak self] in
                self?.onShow?(request)
            }
        case "ping":
            reply("{\"ok\":true}\n")
        case "state":
            // Diagnostic: current card/entry counts (used by the smoke test to
            // prove cards survive a daemon restart). The stack owns AppKit
            // windows, so the answer is computed on the main thread — WITHOUT
            // blocking this socket thread (a jump can hold the main thread in
            // osascript for seconds).
            DispatchQueue.main.async { [weak self] in
                let summary = self?.onState?() ?? "{\"ok\":false}"
                reply(summary + "\n")
                close(fd)
            }
            return true
        case "clear":
            // The user resolved a pending approval/question in the GUI: drop the
            // row that was waiting on it. Runs on the main thread (the stack owns
            // AppKit windows and the snapshot store).
            let sessionId = object["sessionId"] as? String
            let ref = object["ref"] as? String
            guard let sessionId, !sessionId.isEmpty, let ref, !ref.isEmpty else {
                reply("{\"ok\":false,\"reason\":\"bad-request\"}\n")
                break
            }
            DispatchQueue.main.async { [weak self] in
                let result = self?.onClear?(sessionId, ref) ?? "{\"ok\":false}"
                reply(result + "\n")
                close(fd)
            }
            return true
        case "probe":
            // Health check: the daemon is up. (Browser automation probing was
            // removed — session jumps now use a hash deep link opened with the
            // system `open` command, needing no browser scripting permission.)
            reply("{\"ok\":true,\"daemon\":true}\n")
        case "debug":
            // On-demand diagnostic: run a full jump (as if a card was clicked)
            // and reply when it settles. Payload:
            //   {url, sessionId, sessionTitle}          — navigate (completed/error)
            //   {url, sessionId, sessionTitle, focusOnly:true} — focus only (blocked)
            let url = object["url"] as? String
            let sessionId = object["sessionId"] as? String
            let sessionTitle = object["sessionTitle"] as? String
            let focusOnly = (object["focusOnly"] as? Bool) ?? false
            let turn = object["turn"] as? Int
            let driven = BrowserJumper.jump(
                url: url, sessionId: sessionId, sessionTitle: sessionTitle,
                turn: turn, focusOnly: focusOnly
            )
            // Same signal a card click uses: was the command delivered to a
            // browser (the card is dropped only then).
            reply("{\"ok\":true,\"driven\":\(driven)}\n")
        default:
            break
        }
        return false
    }

    var onShow: ((ShowRequest) -> Void)?
    /// Handles `{cmd:"clear", sessionId, ref}`: returns a JSON reply string.
    var onClear: ((String, String) -> String)?
    /// Returns a JSON state summary for the `state` diagnostic command.
    var onState: (() -> String)?
}

// MARK: - Main

let arguments = CommandLine.arguments
let socketPath = arguments.count > 1 ? arguments[1] : "/tmp/dsh-notify-macos.sock"

// A socket server must survive a peer that hangs up before reading its reply:
// without this, writing to a closed socket raises SIGPIPE and kills the daemon
// silently (no crash report, empty log — observed as "the daemon just
// disappeared"). The write helper ignores write() failures; this makes them
// non-fatal instead of terminating the process.
signal(SIGPIPE, SIG_IGN)

// Only one daemon may own the socket; if another is alive, exit quietly.
if daemonAlreadyRunning(socketPath) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let cardStore = CardStackStore(url: URL(fileURLWithPath: socketPath + ".cards.json"))
let stack = CardStack(store: cardStore)
let server = SocketServer(path: socketPath)
server.onShow = { request in
    stack.show(request: request)
}
server.onState = { stack.stateSummary() }
server.onClear = { sessionId, ref in stack.clear(sessionId: sessionId, ref: ref) }
server.start()

app.run()
