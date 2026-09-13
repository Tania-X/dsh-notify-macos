import Foundation

// MARK: - 谁可以连这个 socket
//
// 威胁模型（issue #32）：守护进程渲染卡片、点卡片会用 AppleScript 驱动浏览器。
// 同机**其他用户**若能连上 socket，就能往你的桌面推任意内容的卡片，并借你的
// 权限触发浏览器跳转。socket 文件的权限是防线之一，但 bind 出来的默认权限受
// umask 影响（实测 0755），所以真正的判定放在内核给出的对端 uid 上。
//
// 判定写成纯函数：可单测、可复述、日志文案也在同一处，避免"策略在文档里、
// 实现里是另一回事"。

public enum PeerPolicy {
    public enum Decision: Equatable {
        case accept(reason: String)
        case reject(reason: String)
    }

    /// 接受同一个 uid（正常路径），以及 root。
    ///
    /// 放行 root 是**有意的**：root 本来就能读写本进程内存、杀掉守护进程、
    /// 直接读快照文件 —— 拒绝它不增加任何安全性，只会在有人用 sudo 脚本时
    /// 变成一个查不出原因的故障面。真正要挡的是同机其他普通用户。
    public static func decide(peerUid: UInt32, daemonUid: UInt32) -> Decision {
        if peerUid == daemonUid {
            return .accept(reason: "对端与守护进程同 uid（\(daemonUid)）")
        }
        if peerUid == 0 {
            return .accept(reason: "对端是 root：root 本就能控制本进程，拒绝只增加故障面")
        }
        return .reject(
            reason: "拒绝 uid=\(peerUid) 的连接（本进程 uid=\(daemonUid)）："
                + "socket 只服务同一个用户"
        )
    }
}
