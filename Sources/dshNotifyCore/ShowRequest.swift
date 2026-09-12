import Foundation

/// One decoded request from the socket protocol (JSON Lines).
/// Pure DTO: parsing of the raw JSON dictionary stays in the app target's
/// SocketServer; this type only carries the decoded fields.
public struct ShowRequest {
    public let cmd: String
    public let title: String?
    public let message: String?
    /// Outcome kind: "completed" | "error" | "blocked" (default completed).
    public let kind: String?
    /// Structured detail for error/blocked (error message / tool name).
    public let detail: String?
    public let action: String?
    public let path: String?
    public let url: String?
    public let sessionId: String?
    public let sessionTitle: String?
    public let sound: Bool?
    public let autoDismissSec: Double?
    /// Turn whose completion the click should scroll to (position-indexed jump).
    public let turn: Int?
    /// Correlation key of the pending user action this row waits on (blocked
    /// rows): `approval:<id>` / `ask:<callId>`. Lets the daemon drop exactly
    /// that row when the user resolves it in the GUI.
    public let ref: String?

    public init(
        cmd: String,
        title: String?,
        message: String?,
        kind: String?,
        detail: String?,
        action: String?,
        path: String?,
        url: String?,
        sessionId: String?,
        sessionTitle: String?,
        sound: Bool?,
        autoDismissSec: Double?,
        turn: Int?,
        ref: String? = nil
    ) {
        self.cmd = cmd
        self.title = title
        self.message = message
        self.kind = kind
        self.detail = detail
        self.action = action
        self.path = path
        self.url = url
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.sound = sound
        self.autoDismissSec = autoDismissSec
        self.turn = turn
        self.ref = ref
    }
}
