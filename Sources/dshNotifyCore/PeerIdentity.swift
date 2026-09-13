import Darwin
import Foundation

// MARK: - 对端身份
//
// AF_UNIX 的 `getpeereid()`：内核保证这**不是**对端自称的身份，而是连接的
// 真实另一端（和 Linux 的 SO_PEERCRED 同源）—— 所以它可以直接用来做访问控制，
// 不像 JSON 报文里的任何字段那样可以被伪造。
//
// 只有 socket 相关的最薄一层放在这里；策略在 PeerPolicy（纯函数）。

public enum PeerIdentity {
    /// 连接对端的 uid；拿不到（fd 非法、非 AF_UNIX 等）返回 nil。
    public static func uid(ofSocket fd: Int32) -> UInt32? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return UInt32(uid)
    }
}
