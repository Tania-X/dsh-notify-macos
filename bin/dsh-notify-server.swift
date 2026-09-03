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

// MARK: - Models

struct ShowRequest {
    let cmd: String
    let title: String?
    let message: String?
    let action: String?
    let path: String?
    let url: String?
    let sessionId: String?
    let sessionTitle: String?
    let sound: Bool?
    let autoDismissSec: Double?
}

// MARK: - Notification card

final class NotificationCard: NSObject {
    let number: Int
    let title: String
    let message: String
    let action: String
    let path: String?
    let url: String?
    let sessionId: String?
    let sessionTitle: String?
    let window: NSWindow
    let view: CardView

    var onRemoved: ((NotificationCard) -> Void)?
    private var removing = false

    init(number: Int, title: String, message: String, action: String, path: String?, url: String?, sessionId: String? = nil, sessionTitle: String? = nil, autoDismissSec: Double? = nil) {
        self.number = number
        self.title = title
        self.message = message
        self.action = action
        self.path = path
        self.url = url
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle

        let width: CGFloat = 340
        let height = CardView.heightFor(title: title, message: message, width: width)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        self.view = CardView(frame: rect)
        self.window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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
        window.title = "dsh-notify \(number)"
        if let autoDismissSec, autoDismissSec > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissSec) { [weak self] in
                self?.dismiss()
            }
        }
    }

    /// Present the card at the given screen position (top-right stack slot).
    func show(at origin: NSPoint) {
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    /// Perform the click action (jump to the completion location).
    func performAction() {
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
            // Jump the browser to the finished conversation's completion point:
            // first try an in-place session switch (click the sidebar row, no
            // reload), falling back to localStorage + reload.
            BrowserJumper.jump(url: url, sessionId: sessionId, sessionTitle: sessionTitle)
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

/// Card surface: draws the rounded panel, the DSH brand whale mark and two
/// text lines, and handles drag-right-to-dismiss plus click-to-jump.
final class CardView: NSView {
    weak var card: NotificationCard?

    private var dragStart: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragged = false

    override var isOpaque: Bool { false }

    /// The DeepSeek Harness whale mark, expressed as SVG path data (same glyph
    /// as the web UI favicon). Drawn as a vector, so it scales crisply at any
    /// size without bundling a bitmap.
    private static let whaleSVGPath = "M48.8354 10.0479C48.3232 9.79199 48.1025 10.2798 47.8032 10.5278C47.7007 10.6079 47.6143 10.7119 47.5273 10.8076C46.7793 11.624 45.9048 12.1597 44.7622 12.0957C43.0923 12 41.666 12.5356 40.4058 13.8398C40.1377 12.2319 39.2476 11.272 37.8926 10.6558C37.1836 10.3359 36.4668 10.0156 35.9702 9.31982C35.6235 8.82373 35.5293 8.27197 35.356 7.72754C35.2456 7.3999 35.1353 7.06396 34.7651 7.00781C34.3633 6.94385 34.2056 7.2876 34.0479 7.57568C33.418 8.75195 33.1733 10.0479 33.1973 11.3599C33.2524 14.312 34.4736 16.6641 36.8999 18.3359C37.1758 18.5278 37.2466 18.7197 37.1597 19C36.9946 19.5757 36.7974 20.1357 36.624 20.7119C36.5137 21.0801 36.3486 21.1597 35.9624 21C34.6309 20.4321 33.481 19.5918 32.4644 18.5757C30.7393 16.8721 29.1792 14.9917 27.2334 13.52C26.7764 13.1758 26.3193 12.856 25.8467 12.5518C23.8618 10.584 26.1069 8.96777 26.627 8.77588C27.1704 8.57568 26.8159 7.8877 25.0591 7.896C23.3022 7.90381 21.6953 8.50391 19.647 9.30371C19.3477 9.42383 19.0322 9.51172 18.7095 9.58398C16.8501 9.22363 14.9199 9.14355 12.9033 9.37598C9.10596 9.80762 6.07275 11.6396 3.84326 14.7681C1.16455 18.5278 0.53418 22.7998 1.30664 27.2559C2.11768 31.9521 4.46582 35.8398 8.07373 38.8799C11.8159 42.0322 16.1255 43.5762 21.041 43.2803C24.0269 43.104 27.3516 42.6963 31.1016 39.4561C32.0469 39.936 33.0396 40.1279 34.686 40.272C35.9546 40.3921 37.1758 40.208 38.1211 40.0078C39.6021 39.688 39.4995 38.2881 38.9639 38.0322C34.623 35.9678 35.5762 36.8081 34.71 36.1279C36.9155 33.4639 40.2402 30.6958 41.54 21.728C41.6426 21.0161 41.5557 20.5679 41.54 19.9917C41.5322 19.6396 41.6108 19.5039 42.0049 19.4639C43.0923 19.3359 44.1479 19.0317 45.1167 18.4878C47.9292 16.9199 49.064 14.3438 49.3315 11.2559C49.3711 10.7837 49.3237 10.2959 48.8354 10.0479ZM24.3262 37.8398C20.1196 34.4639 18.0791 33.3521 17.2358 33.3999C16.4482 33.4482 16.5898 34.3682 16.7632 34.9678C16.9443 35.5601 17.1812 35.9683 17.5117 36.4878C17.7402 36.832 17.8979 37.3442 17.2832 37.728C15.9282 38.584 13.5728 37.4399 13.4624 37.3838C10.7207 35.7358 8.42822 33.5601 6.81348 30.584C5.25342 27.7197 4.34766 24.6479 4.19775 21.3677C4.1582 20.5757 4.38672 20.2959 5.15869 20.1519C6.17529 19.96 7.22314 19.9199 8.23926 20.0718C12.5327 20.7119 16.1885 22.6719 19.2529 25.7759C21.002 27.5439 22.3252 29.6558 23.6885 31.7202C25.1377 33.9121 26.6978 36 28.6831 37.7119C29.3843 38.312 29.9434 38.7681 30.479 39.104C28.8643 39.2881 26.1699 39.3281 24.3262 37.8398ZM26.3433 24.6001C26.3433 24.248 26.6191 23.9678 26.9658 23.9678C27.0444 23.9678 27.1152 23.9839 27.1782 24.0078C27.2651 24.04 27.3438 24.0879 27.4067 24.1602C27.5171 24.272 27.5801 24.4321 27.5801 24.6001C27.5801 24.9521 27.3042 25.2319 26.9575 25.2319C26.6108 25.2319 26.3433 24.9521 26.3433 24.6001ZM32.6064 27.8799C32.2046 28.0479 31.8027 28.1919 31.4165 28.208C30.8179 28.2397 30.1641 27.9922 29.8096 27.688C29.2583 27.2158 28.8643 26.9521 28.6987 26.1279C28.6279 25.7759 28.6675 25.2319 28.7305 24.9199C28.8721 24.248 28.7144 23.8159 28.2495 23.4238C27.8716 23.104 27.3911 23.0161 26.8633 23.0161C26.666 23.0161 26.4849 22.9277 26.3511 22.856C26.1304 22.7441 25.9492 22.4639 26.1226 22.1201C26.1777 22.0078 26.4458 21.7358 26.5088 21.688C27.2256 21.272 28.0527 21.4077 28.8169 21.7197C29.5259 22.0161 30.0615 22.5601 30.834 23.3281C31.6216 24.2559 31.7632 24.5117 32.2124 25.208C32.5669 25.752 32.8901 26.312 33.1104 26.9521C33.2446 27.3521 33.0713 27.6802 32.6064 27.8799Z"

    /// The whale mark parsed once (at 50x50 logical coordinates, Y flipped to
    /// Cocoa's upward axis), so `draw` only applies an affine transform per
    /// frame instead of re-parsing the SVG path on every render.
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
            path.curve(
                to: NSPoint(x: x, y: 50 - y),
                controlPoint1: NSPoint(x: c1x, y: 50 - c1y),
                controlPoint2: NSPoint(x: c2x, y: 50 - c2y)
            )
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
                    curveTo(
                        CGFloat(numbers[i]), CGFloat(numbers[i + 1]),
                        CGFloat(numbers[i + 2]), CGFloat(numbers[i + 3]),
                        CGFloat(numbers[i + 4]), CGFloat(numbers[i + 5])
                    )
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

    /// Build an `NSBezierPath` for the whale mark fitted inside `rect`.
    /// Maps the cached 50x50 unit path onto the target rect.
    static func whaleMarkPath(in rect: NSRect) -> NSBezierPath {
        let path = whaleMarkUnit.copy() as! NSBezierPath
        let scale = rect.width / 50.0
        var transform = AffineTransform.identity
        transform.translate(x: rect.minX, y: rect.minY)
        transform.scale(x: scale, y: scale)
        path.transform(using: transform)
        return path
    }

    static func heightFor(title: String, message: String, width: CGFloat) -> CGFloat {
        let titleSize = (title as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let messageRect = (message as NSString).boundingRect(
            with: NSSize(width: width - 72, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let content = titleSize.height + messageRect.height + 36
        return max(64, ceil(content))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Panel background (rounded, translucent dark).
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.12, alpha: 0.95).setFill()
        panel.fill()

        guard let card else { return }

        // Brand mark (DeepSeek Harness whale), left of the title.
        let markSize: CGFloat = 24
        let markRect = NSRect(x: 16, y: (bounds.height - markSize) / 2, width: markSize, height: markSize)
        let mark = CardView.whaleMarkPath(in: markRect)
        NSColor(calibratedWhite: 1, alpha: 1).setFill()
        mark.fill()

        // Title line.
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        (card.title as NSString).draw(
            in: NSRect(x: 50, y: bounds.height - 26, width: bounds.width - 64, height: 20),
            withAttributes: titleAttrs
        )

        // Message line(s).
        let messageAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)
        ]
        (card.message as NSString).draw(
            in: NSRect(x: 50, y: 10, width: bounds.width - 64, height: bounds.height - 40),
            withAttributes: messageAttrs
        )
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

        if dragged && dx > 40 {
            // Drag right: dismiss / clear.
            card.dismiss()
        } else if !dragged {
            // Click: run the action, then clear. Browser driving (osascript)
            // can block for ~1-2s, so dispatch it off the main thread and let
            // the dismissal happen immediately on the UI thread.
            let action = card.action
            let jump = { card.performAction() }
            if action == "jump-web" {
                DispatchQueue.global(qos: .userInitiated).async(execute: jump)
            } else {
                jump()
            }
            card.dismiss()
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
}

// MARK: - Browser jumping

/// Drives the browser that hosts the DSH GUI and points it at one session.
///
/// Strategy:
///  1. Discover which browser already has the GUI open (Safari / Chrome /
///     Edge / Brave / Arc / Opera / Firefox), and operate on THAT instance —
///     never on a random browser.
///  2. Inject JS that switches to the target session IN PLACE, without
///     reloading: find the sidebar session row by its title and click it
///     (the GUI then scrolls to that session's newest message, which is the
///     "task done" spot). If the row is not found (e.g. collapsed group or
///     stale title), fall back to setting `localStorage["dsh.sessions.current"]`
///     and reloading — the GUI reopens the session and auto-scrolls to the
///     newest message because the scroll anchor is in-memory only.
///  3. When no scriptable browser is available, at least open the GUI URL.
enum BrowserJumper {
    /// Browsers probed in order; the first one with a GUI tab wins.
    private static let browserCandidates = [
        "Safari", "Google Chrome", "Microsoft Edge", "Brave Browser",
        "Arc", "Opera", "Firefox"
    ]

    /// Escape a value as an AppleScript double-quoted string literal. The
    /// embedded JavaScript uses single-quoted strings, so only the outer
    /// AppleScript quoting needs escaping here.
    private static func asString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Escape a value as a single-quoted JavaScript string literal (embedded
    /// inside the AppleScript double-quoted string).
    private static func jsString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Fallback: set the persisted session and reload (the GUI reopens the
    /// session and scrolls to its newest message).
    /// Fallback when the target session is no longer reachable in the sidebar
    /// (e.g. it was deleted or archived right after completing): clear the
    /// persisted selection and reload, so the GUI falls back to its default —
    /// the first available Session; when none exist the GUI shows its empty /
    /// new-session state, which is the honest minimum we can do.
    private static func clearSelectionAndReloadScript() -> String {
        "localStorage.removeItem('dsh.sessions.current'); location.reload();"
    }

    /// Preferred: switch to the session in place by clicking its sidebar row
    /// (matched by exact title, then by contains), then scroll the chat
    /// scrollport to the bottom. The script returns a JSON diagnostic object
    /// (`{switched, rows, matched, scroller}`) so failures can be read from the
    /// daemon log instead of guessing.
    private static func inPlaceScript(sessionTitle: String?) -> String {
        let exact = (sessionTitle?.isEmpty == false) ? jsString(sessionTitle!) : "null"
        return """
        (function () {
          var diag = { switched: false, rows: 0, matched: null, scroller: false };
          var rows = Array.from(document.querySelectorAll('[role="treeitem"]'));
          diag.rows = rows.length;
          var pick = null;
          var wanted = \(exact);
          if (wanted !== null) {
            for (var i = 0; i < rows.length; i++) {
              var text = (rows[i].textContent || '').trim();
              if (text === wanted) { pick = rows[i]; break; }
            }
            if (!pick) {
              for (var j = 0; j < rows.length; j++) {
                var t = (rows[j].textContent || '').trim();
                if (t.indexOf(wanted) !== -1) { pick = rows[j]; break; }
              }
            }
          }
          if (pick) {
            diag.matched = (pick.textContent || '').trim().slice(0, 60);
            pick.click();
            diag.switched = true;
            // Give React a moment to render the switched session, then scroll.
            var scroller = document.querySelector('[data-conversation-scroll]');
            if (!scroller) {
              var el = document.querySelector('[role="main"], main');
              while (el && el !== document.body) {
                if (el.scrollHeight > el.clientHeight) { scroller = el; break; }
                el = el.parentElement;
              }
            }
            if (scroller) {
              diag.scroller = true;
              var t = 0;
              var id = setInterval(function () {
                scroller.scrollTop = scroller.scrollHeight;
                if (++t > 40) clearInterval(id);
              }, 150);
            }
          }
          return JSON.stringify(diag);
        })()
        """
    }

    /// Run osascript and return its exit code, stdout and stderr.
    /// Diagnostics (non-zero exit or non-empty stderr) are appended to a log
    /// file so jump failures can be debugged on a live machine.
    @discardableResult
    private static func runOSAScript(_ script: String, label: String = "") -> (code: Int32, stdout: String, stderr: String) {
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
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if code != 0 || !errText.isEmpty {
                let line = "[osascript\(label.isEmpty ? "" : " " + label)] exit=\(code) err=\(errText.trimmingCharacters(in: .whitespacesAndNewlines)) out=\(outText.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                log(line)
            }
            return (code, outText, errText)
        } catch {
            log("[osascript\(label.isEmpty ? "" : " " + label)] launch error: \(error)\n")
            return (1, "", String(describing: error))
        }
    }

    /// Append one diagnostic line to the daemon log.
    static func log(_ line: String) {
        let path = "/tmp/dsh-notify-macos.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Whether the daemon may script the named browser (Automation permission
    /// granted). A minimal `get version` Apple event needs no extra grants, so
    /// this is a cheap permission probe.
    static func canScript(_ appName: String) -> Bool {
        let script = """
        tell application \(asString(appName)) to get version
        """
        return runOSAScript(script).code == 0
    }

    /// Pure enumeration probe: reports whether the browser has a GUI tab by
    /// raising `error "dsh-no-tab"` (non-zero exit) when none matches. It does
    /// NOT execute JavaScript, so it works even before the user grants the
    /// "Allow JavaScript from Apple Events" browser setting — we only need tab
    /// enumeration to locate the hosting browser.
    private static func probeScript(appName: String, url: String) -> String {
        if appName == "Safari" {
            return """
            tell application "Safari"
              set found to false
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t starts with \(asString(url)) then
                    set found to true
                    set current tab of w to t
                    set index of w to 1
                    exit repeat
                  end if
                end repeat
                if found then exit repeat
              end repeat
              if not found then error "dsh-no-tab"
            end tell
            """
        }
        return """
        tell application \(asString(appName))
          set found to false
          repeat with w in windows
            repeat with t in tabs of w
              if URL of t starts with \(asString(url)) then
                set found to true
                set active tab index of w to (index of t)
                set index of w to 1
                exit repeat
              end if
            end repeat
            if found then exit repeat
          end repeat
          if not found then error "dsh-no-tab"
        end tell
        """
    }

    /// Inject a script into the GUI tab of the given browser. `openIfMissing`
    /// opens the GUI in that browser first when no tab exists.
    private static func injectScript(
        appName: String, url: String, script: String, openIfMissing: Bool
    ) -> String {
        if appName == "Safari" {
            let resolve = openIfMissing
                ? "open location \(asString(url))\n            set targetDoc to front document"
                : "error \"dsh-no-tab\""
            return """
            tell application "Safari"
              activate
              set targetDoc to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t starts with \(asString(url)) then
                    set targetDoc to t
                    set current tab of w to t
                    set index of w to 1
                    exit repeat
                  end if
                end repeat
                if targetDoc is not missing value then exit repeat
              end repeat
              if targetDoc is missing value then
                \(resolve)
              end if
              do JavaScript \(asString(script)) in targetDoc
            end tell
            """
        }
        let resolve = openIfMissing
            ? "open location \(asString(url))\n            set targetTab to active tab of front window"
            : "error \"dsh-no-tab\""
        return """
        tell application \(asString(appName))
          activate
          set targetTab to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if URL of t starts with \(asString(url)) then
                set targetTab to t
                set active tab index of w to (index of t)
                set index of w to 1
                exit repeat
              end if
            end repeat
            if targetTab is not missing value then exit repeat
          end repeat
          if targetTab is missing value then
            \(resolve)
          end if
          execute targetTab javascript \(asString(script))
        end tell
        """
    }

    /// Find the browser that already hosts the GUI (enumeration only, no JS).
    /// Returns the app name, or nil when no scriptable browser hosts it.
    private static func findHostingBrowser(url: String) -> String? {
        log("[jump] probing browsers for tab: \(url)\n")
        for app in browserCandidates where canScript(app) {
            log("[jump]   probing \(app)...\n")
            if runOSAScript(probeScript(appName: app, url: url), label: "probe-\(app)").code == 0 {
                log("[jump]   -> \(app) hosts the GUI\n")
                return app
            }
            log("[jump]   -> \(app) does NOT host it\n")
        }
        return nil
    }

    /// Jump the browser to the GUI and the given session, staying inside the
    /// browser that hosts the GUI the whole time.
    static func jump(url: String?, sessionId: String?, sessionTitle: String?) {
        let guiUrl = (url?.isEmpty == false) ? url! : "http://127.0.0.1:3080"
        log("[jump] start url=\(guiUrl) sessionId=\(sessionId ?? "nil") title=\(sessionTitle ?? "nil")\n")
        guard let sessionId, !sessionId.isEmpty else {
            // No session to target: just open the GUI.
            if let parsed = URL(string: guiUrl) { NSWorkspace.shared.open(parsed) }
            return
        }
        // 1) Find the hosting browser (enumeration only — no JS needed).
        guard let app = findHostingBrowser(url: guiUrl) else {
            // No scriptable browser hosts the GUI. Open the GUI with the
            // system default handler (last resort).
            log("[jump] no scriptable browser hosts the GUI; opening with default handler\n")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [guiUrl]
            try? process.run()
            return
        }
        // 2) Inject the in-place switch + scroll; the injected script returns a
        //    JSON diagnostic that osascript prints to stdout, which we capture
        //    and log. If the target session's sidebar row is not found (it may
        //    have been deleted/archived right after completing), clear the
        //    persisted selection and reload inside the SAME browser/tab: the
        //    GUI then opens its first available Session, or its empty state if
        //    there are none.
        let js = """
        (function () {
          var diag = \(inPlaceScript(sessionTitle: sessionTitle));
          if (diag && JSON.parse(diag).switched) { return diag; }
          \(clearSelectionAndReloadScript())
          return diag;
        })();
        """
        let injected = injectScript(
            appName: app, url: guiUrl, script: js, openIfMissing: false
        )
        let injectedResult = runOSAScript(injected, label: "inject-\(app)")
        if injectedResult.code == 0 {
            log("[jump] injected in \(app) -> \(injectedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\n")
            return
        }
        // 3) The tab exists but JS injection failed (missing "Allow JavaScript
        //    from Apple Events"): retry once after a settle, then at minimum
        //    focus the GUI tab in the hosting browser (open location activates
        //    the existing tab without reloading).
        Thread.sleep(forTimeInterval: 0.8)
        let retried = runOSAScript(injected, label: "inject-\(app)-retry")
        if retried.code == 0 {
            log("[jump] injected (retry) in \(app) -> \(retried.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\n")
            return
        }
        let focus = injectScript(
            appName: app, url: guiUrl, script: "1", openIfMissing: false
        )
        _ = runOSAScript(focus, label: "focus-\(app)")
        log("[jump] injection failed; focused \(app) only\n")
    }
}

// MARK: - Card stack

final class CardStack {
    private var cards: [NotificationCard] = []
    private var nextNumber = 1
    private let margin: CGFloat = 12
    private let gap: CGFloat = 8

    func show(request: ShowRequest) {
        // Title = the session's name when available (so the user knows WHICH
        // conversation finished), else the configured fallback title.
        let title: String
        if let sessionTitle = request.sessionTitle, !sessionTitle.isEmpty {
            title = sessionTitle
        } else if let t = request.title, !t.isEmpty {
            title = t
        } else {
            title = "DeepSeek Harness"
        }
        let message = request.message.flatMap { $0.isEmpty ? nil : $0 } ?? "任务完成，点击查看详情"
        let action = request.action ?? "open-folder"
        let card = NotificationCard(
            number: nextNumber,
            title: title,
            message: message,
            action: action,
            path: request.path,
            url: request.url,
            sessionId: request.sessionId,
            sessionTitle: request.sessionTitle,
            autoDismissSec: request.autoDismissSec
        )
        nextNumber += 1
        card.onRemoved = { [weak self] removed in
            self?.remove(removed)
        }
        cards.append(card)
        relayout(animated: false)
        if request.sound == true {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
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
                card.show(at: targetOrigin)
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
            // Report browser automation permission state (used by the plugin's
            // README and diagnostics to guide the user through the one-time
            // macOS Automation + "Allow JavaScript from Apple Events" grants).
            let chrome = BrowserJumper.canScript("Google Chrome")
            let safari = BrowserJumper.canScript("Safari")
            reply("{\"ok\":true,\"chrome\":\(chrome ? "true" : "false"),\"safari\":\(safari ? "true" : "false")}\n")
        case "debug":
            // On-demand diagnostic: run a full jump (as if a card was clicked)
            // and reply when it settles. Payload: {url, sessionId, sessionTitle}.
            let url = object["url"] as? String
            let sessionId = object["sessionId"] as? String
            let sessionTitle = object["sessionTitle"] as? String
            BrowserJumper.jump(url: url, sessionId: sessionId, sessionTitle: sessionTitle)
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
