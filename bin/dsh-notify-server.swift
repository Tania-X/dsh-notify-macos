// dsh-notify-server — persistent top-right floating notification daemon.
//
// Renders numbered notification cards pinned to the top-right corner of the
// screen. Each card stays until the user acts:
//   - drag it to the right  -> dismiss (clear) it
//   - click it              -> run the click action (e.g. reveal the session's
//                              working directory in Finder, or open the Web UI)
//                              and dismiss it
// Multiple cards may be shown at once; each carries an incrementing number so
// simultaneously-finished tasks stay distinguishable.
//
// Protocol: one JSON object per line over a Unix domain socket.
//   {"cmd":"show","title":"...","message":"...","action":"open-folder|open-web|none","path":"/abs/path","url":"http://...","sound":true}
//   {"cmd":"ping"}  -> replies {"ok":true}
//   {"cmd":"quit"}  -> terminates the daemon
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

/// Card surface: draws the rounded panel, number badge and two text lines, and
/// handles drag-right-to-dismiss plus click-to-jump.
final class CardView: NSView {
    weak var card: NotificationCard?

    private var dragStart: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragged = false

    override var isOpaque: Bool { false }

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

        // Number badge.
        let badgeSize: CGFloat = 26
        let badgeRect = NSRect(x: 14, y: (bounds.height - badgeSize) / 2, width: badgeSize, height: badgeSize)
        let badge = NSBezierPath(ovalIn: badgeRect)
        NSColor.systemBlue.setFill()
        badge.fill()
        let numberText = "\(card.number)" as NSString
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        let numberSize = numberText.size(withAttributes: numberAttrs)
        numberText.draw(
            at: NSPoint(x: badgeRect.midX - numberSize.width / 2, y: badgeRect.midY - numberSize.height / 2),
            withAttributes: numberAttrs
        )

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
            // Click: jump to the completion location, then clear.
            card.performAction()
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

    /// Run osascript with a script; returns true when it exited 0.
    /// Diagnostics (exit code + stderr) are appended to a log file so jump
    /// failures can be debugged on a live machine.
    @discardableResult
    private static func runOSAScript(_ script: String, label: String = "") -> Bool {
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
            return code == 0
        } catch {
            log("[osascript\(label.isEmpty ? "" : " " + label)] launch error: \(error)\n")
            return false
        }
    }

    /// Like `runOSAScript` but returns the captured stdout (e.g. the JSON
    /// diagnostic printed by an injected script) on success, nil on failure.
    static func runOSAScriptCapture(_ script: String, label: String = "") -> String? {
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
            return code == 0 ? outText : nil
        } catch {
            log("[osascript\(label.isEmpty ? "" : " " + label)] launch error: \(error)\n")
            return nil
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
        return runOSAScript(script)
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
            if runOSAScript(probeScript(appName: app, url: url), label: "probe-\(app)") {
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
        if let diag = runOSAScriptCapture(injected, label: "inject-\(app)") {
            log("[jump] injected in \(app) -> \(diag)\n")
            return
        }
        // 3) The tab exists but JS injection failed (missing "Allow JavaScript
        //    from Apple Events"): retry once after a settle, then at minimum
        //    focus the GUI tab in the hosting browser (open location activates
        //    the existing tab without reloading).
        Thread.sleep(forTimeInterval: 0.8)
        if let diag = runOSAScriptCapture(injected, label: "inject-\(app)-retry") {
            log("[jump] injected (retry) in \(app) -> \(diag)\n")
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
        let message = request.message?.isEmpty == false ? request.message! : "任务完成，点击查看详情"
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
                handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        currentClient = client
        defer { currentClient = -1 }
        var buffer = Data()
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1 {
            if byte == 0x0A {
                processLine(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        if !buffer.isEmpty { processLine(buffer) }
        close(client)
    }

    private func processLine(_ data: Data) {
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
            let reply = "{\"ok\":true}\n"
            reply.withCString { ptr in
                _ = Darwin.write(currentClient, ptr, reply.count)
            }
        case "probe":
            // Report browser automation permission state (used by the plugin's
            // README and diagnostics to guide the user through the one-time
            // macOS Automation + "Allow JavaScript from Apple Events" grants).
            let chrome = BrowserJumper.canScript("Google Chrome")
            let safari = BrowserJumper.canScript("Safari")
            let reply = "{\"ok\":true,\"chrome\":\(chrome ? "true" : "false"),\"safari\":\(safari ? "true" : "false")}\n"
            reply.withCString { ptr in
                _ = Darwin.write(currentClient, ptr, reply.count)
            }
        case "debug":
            // On-demand diagnostic: run a full jump (as if a card was clicked)
            // and return the osascript result. Payload: {url, sessionId, sessionTitle}.
            let url = object["url"] as? String
            let sessionId = object["sessionId"] as? String
            let sessionTitle = object["sessionTitle"] as? String
            DispatchQueue.global(qos: .userInitiated).async {
                BrowserJumper.jump(url: url, sessionId: sessionId, sessionTitle: sessionTitle)
                let reply = "{\"ok\":true}\n"
                reply.withCString { ptr in
                    _ = Darwin.write(self.currentClient, ptr, reply.count)
                }
            }
        default:
            break
        }
    }

    /// Client fd being handled right now (for synchronous ping replies).
    private var currentClient: Int32 = -1

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
