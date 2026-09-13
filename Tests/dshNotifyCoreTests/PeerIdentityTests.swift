import XCTest
@testable import dshNotifyCore

/// `getpeereid()` 这层壳。
///
/// 用真的 `socketpair` 走一遍，而不是把 syscall 打桩 —— 打桩只能证明"我调了它"，
/// 证明不了"它在这个平台上的语义是我以为的那样"（uid 取的是对端、拿不到时返回
/// nil 而不是 0）。0 恰好是个危险的默认值：它会被 PeerPolicy 当成 root 放行。
final class PeerIdentityTests: XCTestCase {
    func testServerSideSeesTheClientsUid() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0, "socketpair 失败")
        defer { close(fds[0]); close(fds[1]) }

        // 自己连自己：两端都应是当前 uid（同机跨用户时对端会是对方的 uid）。
        XCTAssertEqual(PeerIdentity.uid(ofSocket: fds[0]), UInt32(getuid()))
        XCTAssertEqual(PeerIdentity.uid(ofSocket: fds[1]), UInt32(getuid()))
    }

    func testInvalidDescriptorYieldsNil() {
        XCTAssertNil(PeerIdentity.uid(ofSocket: -1), "非法 fd 必须返回 nil，不能退化成 0")
    }

    func testClosedDescriptorYieldsNil() {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            return XCTFail("socketpair 失败")
        }
        close(fds[0])
        close(fds[1])
        XCTAssertNil(PeerIdentity.uid(ofSocket: fds[0]), "已关闭的 fd 必须返回 nil")
    }

    /// fd 不是 socket（这里是普通文件）时同样不能猜。
    func testNonSocketDescriptorYieldsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-identity-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return XCTFail("open 失败") }
        defer { close(fd) }
        XCTAssertNil(PeerIdentity.uid(ofSocket: fd), "非 socket 的 fd 必须返回 nil")
    }
}
