import XCTest
@testable import dshNotifyCore

/// 谁可以连 socket（issue #32）。
///
/// 这些用例钉住的是**策略**，不是 syscall —— 策略被改掉时（比如有人顺手把
/// "同 uid" 放宽成"任何本地用户"）必须有一条测试先红，而不是等到某天在日志里
/// 发现陌生 uid 推过卡片。
final class PeerPolicyTests: XCTestCase {
    private let me: UInt32 = 501
    private let stranger: UInt32 = 502

    func testSameUidIsAccepted() {
        guard case .accept(let reason) = PeerPolicy.decide(peerUid: me, daemonUid: me) else {
            return XCTFail("同一个 uid 必须放行")
        }
        XCTAssertTrue(reason.contains("\(me)"), "放行理由里要能看出是哪个 uid：\(reason)")
    }

    func testRootIsAcceptedByDesign() {
        // 有意的决定，不是遗漏：root 本就能控制本进程，拒绝它只增加故障面。
        guard case .accept = PeerPolicy.decide(peerUid: 0, daemonUid: me) else {
            return XCTFail("root 按策略放行（见 PeerPolicy 注释）")
        }
    }

    func testOtherUidIsRejected() {
        guard case .reject(let reason) = PeerPolicy.decide(peerUid: stranger, daemonUid: me) else {
            return XCTFail("其他用户的连接必须被拒绝")
        }
        XCTAssertTrue(reason.contains("\(stranger)"), "拒绝理由要含对端 uid：\(reason)")
        XCTAssertTrue(reason.contains("\(me)"), "拒绝理由要含本进程 uid：\(reason)")
    }

    /// 反过来问一遍：策略的方向不能是"默认放行、特例拒绝"。
    func testDecisionIsNotDefaultAccept() {
        var accepted = 0
        for peer: UInt32 in [1, 2, 500, 502, 503, 1000] {
            if case .accept = PeerPolicy.decide(peerUid: peer, daemonUid: me) { accepted += 1 }
        }
        XCTAssertEqual(accepted, 0, "除同 uid 与 root 外，任何 uid 都不该放行")
    }
}
