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
    let window: NSWindow
    let view: CardView

    var onRemoved: ((NotificationCard) -> Void)?
    private var removing = false

    init(number: Int, title: String, message: String, action: String, path: String?, url: String?, autoDismissSec: Double? = nil) {
        self.number = number
        self.title = title
        self.message = message
        self.action = action
        self.path = path
        self.url = url

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

// MARK: - Card stack

final class CardStack {
    private var cards: [NotificationCard] = []
    private var nextNumber = 1
    private let margin: CGFloat = 12
    private let gap: CGFloat = 8

    func show(request: ShowRequest) {
        let title = request.title?.isEmpty == false ? request.title! : "DeepSeek Harness"
        let message = request.message?.isEmpty == false ? request.message! : "任务已完成"
        let action = request.action ?? "open-folder"
        let card = NotificationCard(
            number: nextNumber,
            title: title,
            message: message,
            action: action,
            path: request.path,
            url: request.url,
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
