import XCTest
@testable import dshNotifyCore

/// Socket 协议的纯逻辑（分帧 + socket 级回复）。
///
/// 分帧是历史上真出过事故的地方：请求没带结尾换行时，守护进程会一直阻塞在
/// `read()`，直到对端关闭才处理 —— 调用方看到"超时"，而请求其实是"处理成功了"
/// （docs/troubleshooting.md §21）。所以这些不变量值得钉住。
final class SocketProtocolTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func text(_ data: Data?) -> String? {
        data.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: 分帧

    func testNoNewlineYetYieldsNothing() {
        var frames = SocketRequestBuffer()
        XCTAssertNil(frames.feed(data("{\"cmd\":\"ping\"}")))
        XCTAssertFalse(frames.isEmpty)
    }

    func testCompleteLineIsReturnedWithoutTheNewline() {
        var frames = SocketRequestBuffer()
        XCTAssertEqual(text(frames.feed(data("{\"cmd\":\"ping\"}\n"))), "{\"cmd\":\"ping\"}")
    }

    func testLineSplitAcrossChunks() {
        var frames = SocketRequestBuffer()
        XCTAssertNil(frames.feed(data("{\"cmd\":")))
        XCTAssertNil(frames.feed(data("\"sta")))
        XCTAssertEqual(text(frames.feed(data("te\"}\n"))), "{\"cmd\":\"state\"}")
    }

    func testCarriageReturnIsTolerated() {
        var frames = SocketRequestBuffer()
        XCTAssertEqual(text(frames.feed(data("{\"cmd\":\"ping\"}\r\n"))), "{\"cmd\":\"ping\"}")
    }

    func testPeerReplyCarriesTheUid() {
        XCTAssertEqual(SocketReply.peer(uid: 501), "{\"ok\":true,\"uid\":501}\n")
    }

    func testOnlyTheFirstRequestIsTaken() {
        // 一个连接只处理一条请求（客户端每条命令新开连接）。
        var frames = SocketRequestBuffer()
        XCTAssertEqual(text(frames.feed(data("{\"cmd\":\"ping\"}\n{\"cmd\":\"state\"}\n"))), "{\"cmd\":\"ping\"}")
    }

    func testEmptyLineIsIgnored() {
        var frames = SocketRequestBuffer()
        XCTAssertNil(frames.feed(data("\n")))
        XCTAssertTrue(frames.isEmpty)
    }

    // MARK: 对端提前关闭

    func testRemainderIsProcessedWhenThePeerNeverSentANewline() {
        var frames = SocketRequestBuffer()
        _ = frames.feed(data("{\"cmd\":\"ping\"}"))
        XCTAssertEqual(text(frames.remainder()), "{\"cmd\":\"ping\"}")
        XCTAssertTrue(frames.isEmpty)
    }

    func testRemainderIsNilWhenNothingBuffered() {
        var frames = SocketRequestBuffer()
        XCTAssertNil(frames.remainder())
        _ = frames.feed(data("{\"cmd\":\"ping\"}\n"))
        XCTAssertNil(frames.remainder())
    }

    // MARK: socket 级回复（形状被客户端与冒烟脚本依赖）

    func testSocketLevelReplies() {
        XCTAssertEqual(SocketReply.ping, "{\"ok\":true}\n")
        XCTAssertEqual(SocketReply.daemon, "{\"ok\":true,\"daemon\":true}\n")
        XCTAssertEqual(SocketReply.badRequest, "{\"ok\":false,\"reason\":\"bad-request\"}\n")
        XCTAssertEqual(SocketReply.unavailable, "{\"ok\":false}\n")
        XCTAssertEqual(SocketReply.debugDriven(true), "{\"ok\":true,\"driven\":true}\n")
        XCTAssertEqual(SocketReply.debugDriven(false), "{\"ok\":true,\"driven\":false}\n")
    }

    func testTerminatedAddsExactlyOneNewline() {
        XCTAssertEqual(SocketReply.terminated("{\"ok\":true}"), "{\"ok\":true}\n")
        XCTAssertEqual(SocketReply.terminated("{\"ok\":true}\n"), "{\"ok\":true}\n")
    }
}
