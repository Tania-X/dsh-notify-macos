import Foundation

/// Socket 协议的**纯逻辑**部分：分帧与 socket 级回复。
///
/// 为什么放在 Core：这两块是协议里最容易出错、也最容易测的地方 ——
/// 分帧错了会让守护进程**阻塞在读里**（历史上真实事故：请求没带结尾换行，
/// 守护进程一直等到对端关闭才处理，调用方看到"超时"，见 docs/troubleshooting.md §21），
/// 而回复是手拼 JSON，最怕悄悄改坏形状让客户端解析不到。
public enum SocketProtocol {
    /// 请求分隔符：一条请求一行（JSON Lines）。
    public static let newline: UInt8 = 0x0A
    /// 回复也以换行结尾。
    public static let replyTerminator = "\n"
}

/// 请求分帧缓冲。
///
/// 约定：**一个连接处理一条请求**（客户端每条命令新开一个连接），所以 `feed`
/// 一旦拿到第一个完整行就可以把它交给业务层。
public struct SocketRequestBuffer {
    private var buffer = Data()

    public init() {}

    public var isEmpty: Bool { buffer.isEmpty }

    /// 喂入一段字节；攒够一个换行时返回这一行（不含换行，兼容 CRLF）。
    ///
    /// - Parameter chunk: 本次 `read(2)` 读到的字节。
    /// - Returns: 完整请求的字节，或 nil（还没读到换行）。
    public mutating func feed(_ chunk: Data) -> Data? {
        buffer.append(chunk)
        guard let index = buffer.firstIndex(of: SocketProtocol.newline) else { return nil }
        let line = buffer[buffer.startIndex..<index]
        // 一个连接只处理一条请求：拿到行后就不再保留后续字节。
        buffer.removeAll(keepingCapacity: true)
        return Self.trimmed(line)
    }

    /// 对端没有用换行结尾就关闭了连接：缓冲区里剩下的内容仍要处理。
    ///
    /// 协议要求换行，但我们不能因此**静默丢掉**一条已经写进来的请求（§21 的事故就长这样）。
    /// - Returns: 残留请求的字节，或 nil（没有残留）。
    public mutating func remainder() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let rest = buffer
        buffer.removeAll(keepingCapacity: true)
        return Self.trimmed(rest)
    }

    /// 去掉尾部的 `\r`（CRLF 宽容）并丢弃空行。
    private static func trimmed(_ slice: Data.SubSequence) -> Data? {
        var data = Data(slice)
        while data.last == 0x0D { data.removeLast() }
        return data.isEmpty ? nil : data
    }
}

/// Socket 层的回复（socket 级命令；卡片栈自己的载荷仍由 CardStack 生成）。
public enum SocketReply {
    /// `ping` 存活探测。
    public static let ping = "{\"ok\":true}" + SocketProtocol.replyTerminator
    /// `probe` 守护进程健康探测。
    public static let daemon = "{\"ok\":true,\"daemon\":true}" + SocketProtocol.replyTerminator
    /// 请求本身不合法（缺字段等）。
    public static let badRequest = "{\"ok\":false,\"reason\":\"bad-request\"}" + SocketProtocol.replyTerminator
    /// 主线程回不来时的兜底。
    public static let unavailable = "{\"ok\":false}" + SocketProtocol.replyTerminator

    /// `debug` 诊断：这次跳转有没有交给浏览器（与卡片点击用的同一个信号）。
    public static func debugDriven(_ driven: Bool) -> String {
        "{\"ok\":true,\"driven\":\(driven)}" + SocketProtocol.replyTerminator
    }

    /// 给可能没有换行的载荷补上换行（`state` / `clear` 的载荷来自 CardStack）。
    public static func terminated(_ payload: String) -> String {
        payload.hasSuffix(SocketProtocol.replyTerminator)
            ? payload
            : payload + SocketProtocol.replyTerminator
    }
}
