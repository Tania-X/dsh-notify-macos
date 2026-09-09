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

    /// Pure aggregation state machine (extracted to dshNotifyCore for tests).
    let model = CardModel()

    var onRemoved: ((NotificationCard) -> Void)?
    var onToggleExpanded: ((NotificationCard) -> Void)?
    private var removing = false

    /// Card dimensions.
    static let width: CGFloat = 360
    static let headerHeight: CGFloat = 56
    static let rowHeight: CGFloat = 30
    static let collapsedHeight = headerHeight

    init(sessionId: String?, sessionTitle: String, action: String, path: String?, url: String?, autoDismissSec: Double? = nil) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.action = action
        self.path = path
        self.url = url
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
        if let autoDismissSec, autoDismissSec > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissSec) { [weak self] in
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
    func addCompletion(message: String, kind: OutcomeKind, detail: String?, at time: Date = Date()) -> Int {
        let index = model.addCompletion(message: message, kind: kind, detail: detail, at: time)
        updateFrame()
        return index
    }

    /// Remove one completion by its 1-based arrival index (state in the
    /// model; re-stacks here). Returns the removed entry, or nil.
    @discardableResult
    func removeCompletion(index: Int) -> CompletionEntry? {
        let removed = model.removeCompletion(index: index)
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
    func performAction(focusOnly: Bool = false) {
        switch action {
        case "open-folder":
            if let path, !path.isEmpty {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        case "open-web":
            if let url, let parsed = URL(string: url) {
                NSWorkspace.shared.open(parsed)
            }
        case "jump-web":
            // Jump the browser to the finished conversation's completion point.
            // (Position-indexed jumps are a later iteration; for now every row
            // targets the session's newest message.)
            BrowserJumper.jump(
                url: url, sessionId: sessionId, sessionTitle: sessionTitle,
                focusOnly: focusOnly
            )
        default:
            break
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
        jump(card)
        card.dismiss()
    }

    /// Jump to one row's completion, then remove that row. When the last row
    /// is removed the card dismisses itself (onRemoved → CardStack.remove).
    /// BLOCKED rows deep-link to their session like any other; removing the
    /// row just marks it handled.
    private func jumpAndRemoveRow(_ card: NotificationCard, row: Int) {
        jump(card)
        let removed = card.removeCompletion(index: row)
        if removed != nil {
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
    }

    /// Dispatch the card action off the main thread when it drives a browser.
    private func jump(_ card: NotificationCard, focusOnly: Bool = false) {
        let action = card.action
        let run = { card.performAction(focusOnly: focusOnly) }
        if action == "jump-web" {
            DispatchQueue.global(qos: .userInitiated).async(execute: run)
        } else {
            run()
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

    /// Browsers probed in order; the first one hosting the GUI tab wins.
    /// The names are what AppleScript resolves (stable across system
    /// languages); the bundle ids drive the running check (localizedName is
    /// localized, e.g. Safari → "Safari浏览器" on a Chinese system).
    /// Browsers probed in order + bundle ids: data lives in dshNotifyCore
    /// (BrowserCatalog) so tests can assert it; thin computed aliases keep the
    /// call sites unchanged.
    private static var browserCandidates: [String] { BrowserCatalog.candidates }
    private static var browserBundleIds: [String: [String]] { BrowserCatalog.bundleIds }

    /// Escape a value as an AppleScript double-quoted string literal.
    private static func asString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Run osascript with a script; returns its exit code, stdout, stderr.
    @discardableResult
    private static func runOSAScript(
        _ script: String, label: String = ""
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
            process.waitUntilExit()
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

    /// Whether the named browser is currently running (cheap lookup, no Apple
    /// events, so a transient Automation denial never hides a running browser).
    private static func isRunning(_ appName: String) -> Bool {
        guard let ids = browserBundleIds[appName] else { return false }
        let running = NSWorkspace.shared.runningApplications
        return running.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return ids.contains(bid)
        }
    }

    /// Outcome of one hosting-tab probe.
    private enum ProbeOutcome {
        case hosted  // tab found and the action (navigate / focus) ran
        case noHost  // browser ran but no tab shows the GUI — try next browser
        case denied  // Apple events denied (e.g. transient -10004) — retry
    }

    /// Classify an osascript result: exit 0 = hosted; our own "dsh-no-tab"
    /// error = noHost; anything else (permission errors, etc.) = denied.
    private static func classify(
        _ result: (code: Int32, stdout: String, stderr: String)
    ) -> ProbeOutcome {
        if result.code == 0 { return .hosted }
        if result.stderr.contains("dsh-no-tab") { return .noHost }
        return .denied
    }

    /// Activate the browser app via the MODERN NSRunningApplication API so
    /// only its frontmost window (the GUI one just raised) comes forward.
    /// AppleScript `activate` uses legacy semantics that raise EVERY window
    /// of the app on EVERY Space: when the user clicks a card from another
    /// desktop, that desktop's browser window ends up stacked above the app
    /// they were using (e.g. a Markdown editor). The modern API (Big Sur+)
    /// without `.activateAllWindows` only activates + switches to the Space
    /// of the app's active window, leaving other Spaces' stacking untouched.
    private static func activateApp(_ appName: String) -> Bool {
        guard let primaryId = browserBundleIds[appName]?.first,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == primaryId
              })
        else { return false }
        // No options: modern (macOS 14+) activation — activates the app and
        // its active window without raising windows on other Spaces.
        return app.activate(options: [])
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
                set current tab of (first window whose tabs contains targetTab) to targetTab
                set index of (first window whose tabs contains targetTab) to 1
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
                set active tab index of (first window whose tabs contains targetTab) to (index of targetTab)
                set index of (first window whose tabs contains targetTab) to 1
              else
                error "dsh-no-tab"
              end if
            end tell
            """
        }
        let outcome = classify(runOSAScript(script, label: "focus-\(appName)"))
        if outcome == .hosted {
            dshLog("[focus] \(appName) tab raised; modern-activating\n")
            _ = activateApp(appName)
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
                set URL of targetTab to \(asString(targetURL))
                set current tab of (first window whose tabs contains targetTab) to targetTab
                set index of (first window whose tabs contains targetTab) to 1
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
              set active tab index of (first window whose tabs contains targetTab) to (index of targetTab)
              set index of (first window whose tabs contains targetTab) to 1
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
            dshLog("[navigate] \(appName) tab updated; modern-activating\n")
            _ = activateApp(appName)
        }
        return outcome
    }

    /// The deep-link hash the client half listens for.
    static func jumpURL(url: String?, sessionId: String) -> String {
        let base = (url?.isEmpty == false) ? url! : guiBaseUrl
        return "\(base)/#dsh-notify-macos/session=\(sessionId)"
    }

    /// Jump: point the hosting browser tab at the hashed GUI URL so the
    /// client half switches sessions in place; fall back to `open` when no
    /// browser hosts the GUI yet. When `focusOnly` is true (a card waiting on
    /// the user, e.g. approval/answer) it activates the hosting tab without
    /// navigating — the pending UI is already there.
    static func jump(url: String?, sessionId: String?, sessionTitle: String?, focusOnly: Bool = false) {
        dshLog("[jump] start focusOnly=\(focusOnly) url=\(url ?? "nil") sessionId=\(sessionId ?? "nil") title=\(sessionTitle ?? "nil")\n")
        let guiUrl = (url?.isEmpty == false) ? url! : guiBaseUrl
        guard let sessionId, !sessionId.isEmpty else {
            if let parsed = URL(string: guiUrl) { NSWorkspace.shared.open(parsed) }
            return
        }
        let target = jumpURL(url: url, sessionId: sessionId)
        dshLog("[jump] target=\(target)\n")

        // Try the browser that worked last time first, then the others.
        var order = JumpPolicy.probeOrder(candidates: BrowserCatalog.candidates, preferring: lastHostingBrowser)

        // A -10004 (Apple events denied while e.g. a system dialog owns the
        // focus) is transient: retry the whole probe up to 3 times, but only
        // while some running browser got DENIED. A clean pass where every
        // running browser reports no hosting tab needs no retry.
        for pass in 1...3 {
            var sawDenied = false
            for app in order where isRunning(app) {
                dshLog("[jump] pass \(pass) probing \(app)\n")
                let outcome: ProbeOutcome = focusOnly
                    ? focusHostingTab(appName: app, guiUrl: guiUrl)
                    : navigateHostingTab(appName: app, guiUrl: guiUrl, targetURL: target)
                switch outcome {
                case .hosted:
                    lastHostingBrowser = app
                    dshLog("[jump] \(focusOnly ? "focused" : "navigated") tab in \(app)\n")
                    return
                case .denied:
                    sawDenied = true   // transient? try the whole pass again
                case .noHost:
                    break              // try the next running browser
                }
            }
            if !sawDenied { break }
            if JumpPolicy.shouldRetry(afterPass: pass, sawDenied: sawDenied) {
                Thread.sleep(forTimeInterval: JumpPolicy.retryDelaySeconds)
            }
        }

        // Fallback: system open (GUI loads; client half handles the hash on boot).
        dshLog("[jump] no hosting tab found; falling back to open\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [focusOnly ? guiUrl : target]
        do {
            try process.run()
            process.waitUntilExit()
            dshLog("[jump] open exit=\(process.terminationStatus)\n")
        } catch {
            dshLog("[jump] open failed: \(error)\n")
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

    /// Show a completion. If a card for the same session already exists,
    /// merge into it (append entry, auto-expand optional); else create one.
    func show(request: ShowRequest) {
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

        // Merge into an existing card for the same session.
        if let sessionId = request.sessionId, !sessionId.isEmpty,
           let existing = cards.first(where: { $0.sessionId == sessionId }) {
            existing.addCompletion(message: message, kind: kind, detail: detail)
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
            autoDismissSec: request.autoDismissSec
        )
        card.addCompletion(message: message, kind: kind, detail: detail)
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
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.maxY - margin
        for card in cards {
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
        if !buffer.isEmpty {
            processLine(buffer, replyTo: client)
        }
        close(client)
    }

    private func processLine(_ data: Data, replyTo fd: Int32) {
        // Write a reply (one JSON line) back to the client.
        func reply(_ text: String) {
            text.withCString { ptr in
                _ = Darwin.write(fd, ptr, text.utf8.count)
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let cmd = object["cmd"] as? String else { return }
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
                autoDismissSec: object["autoDismissSec"] as? Double
            )
            DispatchQueue.main.async { [weak self] in
                self?.onShow?(request)
            }
        case "ping":
            reply("{\"ok\":true}\n")
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
            BrowserJumper.jump(
                url: url, sessionId: sessionId, sessionTitle: sessionTitle,
                focusOnly: focusOnly
            )
            reply("{\"ok\":true}\n")
        default:
            break
        }
    }

    var onShow: ((ShowRequest) -> Void)?
}

// MARK: - Main

let arguments = CommandLine.arguments
let socketPath = arguments.count > 1 ? arguments[1] : "/tmp/dsh-notify-macos.sock"

// Only one daemon may own the socket; if another is alive, exit quietly.
if daemonAlreadyRunning(socketPath) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let stack = CardStack()
let server = SocketServer(path: socketPath)
server.onShow = { request in
    stack.show(request: request)
}
server.start()

app.run()
