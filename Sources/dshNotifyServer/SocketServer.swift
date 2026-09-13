import AppKit
import Darwin
import Foundation
import dshNotifyCore

// MARK: - Socket plumbing
//
// 从 main.swift 拆出来（issue #30）：socket 相关的一切集中在这里，
// main.swift 只留「装配 + 运行」。分帧与 socket 级回复的纯逻辑在
// dshNotifyCore.SocketProtocol，可脱离 AppKit 做 XCTest。

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
        // 分帧逻辑在 Core（SocketRequestBuffer）：一个连接一条请求、换行结尾、
        // 对端提前关闭时残留内容仍要处理 —— 这些都是有测试的不变量。
        var frames = SocketRequestBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var request: Data?
        while true {
            let n = read(client, &chunk, chunk.count)
            if n > 0 {
                if let line = frames.feed(Data(chunk[0..<n])) {
                    request = line
                    break
                }
            } else if n == 0 {
                break  // EOF
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        if request == nil {
            // 对端没给换行就关闭：别静默丢掉这条请求（§21 的事故就是这种形状）。
            request = frames.remainder()
        }
        var deferred = false
        if let request {
            deferred = processLine(request, replyTo: client)
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
            reply(SocketReply.ping)
        case "state":
            // Diagnostic: current card/entry counts (used by the smoke test to
            // prove cards survive a daemon restart). The stack owns AppKit
            // windows, so the answer is computed on the main thread — WITHOUT
            // blocking this socket thread (a jump can hold the main thread in
            // osascript for seconds).
            DispatchQueue.main.async { [weak self] in
                let summary = self?.onState?() ?? SocketReply.unavailable
                reply(SocketReply.terminated(summary))
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
                reply(SocketReply.badRequest)
                break
            }
            DispatchQueue.main.async { [weak self] in
                let result = self?.onClear?(sessionId, ref) ?? SocketReply.unavailable
                reply(SocketReply.terminated(result))
                close(fd)
            }
            return true
        case "probe":
            // Health check: the daemon is up. (Browser automation probing was
            // removed — session jumps now use a hash deep link opened with the
            // system `open` command, needing no browser scripting permission.)
            reply(SocketReply.daemon)
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
            reply(SocketReply.debugDriven(driven))
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

