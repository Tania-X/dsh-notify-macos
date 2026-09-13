// Core 自检（无需 XCTest）：把 dshNotifyCore 源码和这份脚本一起编译成可执行文件，
// 在本机跑一遍关键不变量。CI 上的 XCTest 仍是权威基线，这里只是把“只有 CI 才
// 能发现”的错误提前到本地 —— 例如快照夹具的日期格式（store 用 ISO8601 解码，
// 手写 `"time": 1` 会得到 .corrupt）。
//
//   test/core-local-check.sh
import Darwin
import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  PASS: \(label)")
    } else {
        print("  FAIL: \(label)")
        failures += 1
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, "\(label) (got \(actual), want \(expected))")
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// --- 逐行锚点：每行跳自己的位置，重排后不丢 ---
let model = CardModel()
model.addCompletion(message: "newest", kind: .completed, detail: nil, turn: 101)
model.addCompletion(message: "middle", kind: .completed, detail: nil, turn: 60)
model.addCompletion(message: "oldest", kind: .completed, detail: nil, turn: 1)
checkEqual(model.entries.map(\.turn), [101, 60, 1], "each completion keeps its own turn")
checkEqual(model.jumpTurn(forRow: 2, cardTurn: 101), 60, "row 2 jumps to its own anchor")
checkEqual(model.jumpTurn(forRow: nil, cardTurn: 101), 101, "header click falls back to card turn")
checkEqual(model.jumpTurn(forRow: 9, cardTurn: 101), 101, "out-of-range row falls back")
let anchorless = CardModel()
anchorless.addCompletion(message: "no anchor", kind: .completed, detail: nil)
check(anchorless.jumpTurn(forRow: 1, cardTurn: nil) == nil, "no anchor anywhere stays nil")
_ = model.removeCompletion(index: 1)
checkEqual(model.entries.map(\.turn), [60, 1], "reindex keeps each row's anchor")
checkEqual(model.jumpTurn(forRow: 1, cardTurn: 101), 60, "anchor follows the row after removal")

// --- 快照往返：卡片级 + 逐行锚点 ---
let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsh-core-check-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: url) }
let store = CardStackStore(url: url)
store.save(CardStackSnapshot(cards: [
    SnapshotCard(
        sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
        autoDismissSec: nil, turn: 101, expanded: true,
        entries: [
            SnapshotEntry(message: "a", time: t0, kind: "completed", detail: nil, index: 1, turn: 101),
            SnapshotEntry(message: "b", time: t0, kind: "completed", detail: nil, index: 2, turn: 60),
            SnapshotEntry(message: "c", time: t0, kind: "completed", detail: nil, index: 3),
        ]
    )
]))
let loaded = store.load().cards.first
checkEqual(loaded?.turn, 101, "card anchor survives the round trip")
checkEqual(loaded?.entries.map(\.turn), [101, 60, nil], "per-row anchors survive the round trip")
checkEqual(loaded?.entries.count, 3, "entries survive the round trip")

// --- 快照权限：会话标题不该被同机其他用户读到（socket 的信任边界，issue #32）---
let snapshotMode = (try? FileManager.default
    .attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
checkEqual(snapshotMode?.intValue, 0o600, "snapshot is written 0600, not umask-default 0644")
// 顺带钉住"不留临时文件"：save 走的是"写 0600 临时文件再 rename"，失败路径也必须清干净
let leftovers = (try? FileManager.default.contentsOfDirectory(
    atPath: url.deletingLastPathComponent().path
))?.filter { $0.hasPrefix(".\(url.lastPathComponent)") && $0.hasSuffix(".tmp") } ?? []
checkEqual(leftovers.count, 0, "no scratch file is left behind after a save")
// 连续保存两次：目标必须被**原地覆盖**。这里钉的是"先删后改名"那个坑 ——
// FileManager.moveItem 在目标存在时会失败，于是失败路径会把旧快照一起丢掉；
// rename(2) 是原子覆盖，失败时旧文件完好（评审 🟩 指出，属实）。
store.save(CardStackSnapshot(cards: [
    SnapshotCard(
        sessionId: "s2", sessionTitle: "T2", action: "jump-web", path: nil, url: nil,
        autoDismissSec: nil, turn: 7, expanded: false,
        entries: [SnapshotEntry(message: "z", time: t0, kind: "error", detail: nil, index: 1, turn: 7)]
    )
]))
checkEqual(store.load().cards.first?.sessionId, "s2", "a second save overwrites the snapshot in place")
checkEqual(
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue,
    0o600, "the overwritten snapshot is still 0600"
)
// 覆盖失败那条分支也要被执行到：目标不可被覆盖时，**旧状态必须保留、临时文件不能留**。
// （拿一个目录占住目标路径，rename 会失败 —— 旧实现"先 removeItem 再 moveItem"会把
// 这个目录直接删掉，所以这条断言在旧实现下是红的。）
let blockedURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsh-core-check-blocked-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: blockedURL) }
try? FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)
let blockedStore = CardStackStore(url: blockedURL)
blockedStore.save(CardStackSnapshot(cards: []))
var isDir: ObjCBool = false
let stillThere = FileManager.default.fileExists(atPath: blockedURL.path, isDirectory: &isDir)
check(stillThere && isDir.boolValue, "a failed overwrite leaves the existing target untouched")
let blockedLeftovers = (try? FileManager.default.contentsOfDirectory(
    atPath: blockedURL.deletingLastPathComponent().path
))?.filter { $0.hasPrefix(".\(blockedURL.lastPathComponent)") } ?? []
checkEqual(blockedLeftovers.count, 0, "a failed overwrite leaves no scratch file behind")

// --- 旧格式快照（条目没有 turn 键）仍要能加载 ---
let legacyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsh-core-check-legacy-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: legacyURL) }
let legacyStore = CardStackStore(url: legacyURL)
legacyStore.save(CardStackSnapshot(cards: [
    SnapshotCard(
        sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
        autoDismissSec: nil, turn: 101, expanded: false,
        entries: [
            SnapshotEntry(message: "a", time: t0, kind: "completed", detail: nil, index: 1, turn: 101)
        ]
    )
]))
do {
    let data = try Data(contentsOf: legacyURL)
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var cards = root["cards"] as! [[String: Any]]
    var card = cards[0]
    var entries = card["entries"] as! [[String: Any]]
    let dropped = entries[0].removeValue(forKey: "turn")
    check(dropped != nil, "legacy fixture actually drops the per-row turn key")
    card["entries"] = entries
    cards[0] = card
    root["cards"] = cards
    try JSONSerialization.data(withJSONObject: root).write(to: legacyURL)
    let (snapshot, diagnostic) = legacyStore.loadWithDiagnostic()
    checkEqual(diagnostic, .loaded(1), "legacy snapshot (no per-row turn) loads")
    checkEqual(snapshot.cards.first?.turn, 101, "legacy card anchor still readable")
    check(snapshot.cards.first?.entries.first?.turn == nil, "missing per-row turn decodes as nil")
    checkEqual(snapshot.cards.first?.entries.first?.time, t0, "legacy entry time survives")
} catch {
    check(false, "legacy fixture setup threw: \(error)")
}

// --- 行删除按身份：并发点击下不会删错行 ---
let rowModel = CardModel()
let ta = Date(timeIntervalSince1970: 1_700_000_000)
let tb = Date(timeIntervalSince1970: 1_700_000_060)
rowModel.addCompletion(message: "a", kind: .completed, detail: nil, at: ta, turn: 104)
rowModel.addCompletion(message: "b", kind: .completed, detail: nil, at: tb, turn: 98)
rowModel.addCompletion(message: "c", kind: .completed, detail: nil, at: tb, turn: 60)
let clickedRow = rowModel.entries[2]
_ = rowModel.removeCompletion(index: 1)          // 另一次点击先删掉了 row 1
checkEqual(rowModel.index(of: clickedRow), 2, "identity lookup follows the shifted row")
checkEqual(rowModel.removeCompletion(matching: clickedRow)?.message, "c", "identity removal deletes the clicked row")
checkEqual(rowModel.entries.map(\.message), ["b"], "only the clicked row is gone")
check(
    rowModel.removeCompletion(matching: clickedRow) == nil,
    "removing an already-gone row is a no-op"
)

let twinModel = CardModel()
let twinTime = Date(timeIntervalSince1970: 1_700_000_000)
twinModel.addCompletion(message: "same", kind: .error, detail: "E1", at: twinTime, turn: 60)
twinModel.addCompletion(message: "same", kind: .error, detail: "E2", at: twinTime, turn: 61)
let secondTwin = twinModel.entries[1]
checkEqual(twinModel.index(of: secondTwin), 2, "identical message/kind/time rows stay distinguishable by detail+turn")
_ = twinModel.removeCompletion(index: 1)
checkEqual(twinModel.removeCompletion(matching: secondTwin)?.detail, "E2", "identity removal keeps the right twin")

// --- 琥珀行按 ref 精确删除（GUI 里处理完 → 卡片自己走）---
let refModel = CardModel()
refModel.addCompletion(message: "done", kind: .completed, detail: nil, at: ta, turn: 1)
refModel.addCompletion(message: "等待授权：bash", kind: .blocked, detail: "bash", at: ta, turn: 2, ref: "approval:a1")
refModel.addCompletion(message: "等待你的回答", kind: .blocked, detail: "ask_user_question", at: ta, turn: 2, ref: "ask:q1")
refModel.setExpanded(true)
checkEqual(refModel.index(ofRef: "approval:a1"), 2, "ref lookup finds the blocked row")
checkEqual(refModel.removeCompletion(ref: "approval:a1")?.message, "等待授权：bash", "remove by ref deletes the right row")
checkEqual(refModel.entries.map(\.message), ["done", "等待你的回答"], "other rows untouched")
check(refModel.removeCompletion(ref: "approval:a1") == nil, "resolving an unknown ref is a no-op")
check(refModel.expanded, "two rows left: must stay expanded")
checkEqual(refModel.removeCompletion(ref: "ask:q1")?.kind, .blocked, "second blocked row removable by its own ref")
check(!refModel.expanded, "one row left: auto-collapse")
checkEqual(refModel.completionCount, 1, "card keeps the completed row")
let refSnapshot = CardStackSnapshot(cards: [SnapshotCard(
    sessionId: "s", sessionTitle: "T", action: "jump-web", path: nil, url: nil,
    autoDismissSec: nil, turn: 2, expanded: false,
    entries: [SnapshotEntry(message: "wait", time: ta, kind: "blocked", detail: "bash", index: 1, turn: 2, ref: "approval:a9")]
)])
let refURL = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-core-check-ref-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: refURL) }
let refStore = CardStackStore(url: refURL)
refStore.save(refSnapshot)
checkEqual(refStore.load().cards.first?.entries.first?.ref, "approval:a9", "blocked ref survives a restart")

// --- socket 协议纯逻辑：分帧（§21 事故的根源）与 socket 级回复 ---
var frames = SocketRequestBuffer()
check(frames.feed(Data("{\"cmd\":\"ping\"}".utf8)) == nil, "no newline yet: nothing framed")
checkEqual(String(decoding: frames.feed(Data("\n".utf8))!, as: UTF8.self), "{\"cmd\":\"ping\"}", "newline completes the frame")
var split = SocketRequestBuffer()
check(split.feed(Data("{\"cmd\":".utf8)) == nil, "partial chunk buffered")
checkEqual(String(decoding: split.feed(Data("\"state\"}\n".utf8))!, as: UTF8.self), "{\"cmd\":\"state\"}", "frame split across two reads")
var crlf = SocketRequestBuffer()
checkEqual(String(decoding: crlf.feed(Data("{\"a\":1}\r\n".utf8))!, as: UTF8.self), "{\"a\":1}", "CRLF tolerated")
var leftover = SocketRequestBuffer()
_ = leftover.feed(Data("{\"cmd\":\"ping\"}".utf8))
checkEqual(String(decoding: leftover.remainder()!, as: UTF8.self), "{\"cmd\":\"ping\"}", "peer closed without newline: remainder still processed")
var nothing = SocketRequestBuffer()
check(nothing.remainder() == nil, "no remainder when nothing buffered")
var multi = SocketRequestBuffer()
checkEqual(String(decoding: multi.feed(Data("{\"a\":1}\n{\"b\":2}\n".utf8))!, as: UTF8.self), "{\"a\":1}", "one request per connection: only the first line")
checkEqual(SocketReply.ping, "{\"ok\":true}\n", "ping reply shape")
checkEqual(SocketReply.daemon, "{\"ok\":true,\"daemon\":true}\n", "probe reply shape")
checkEqual(SocketReply.badRequest, "{\"ok\":false,\"reason\":\"bad-request\"}\n", "bad-request reply shape")
checkEqual(SocketReply.debugDriven(false), "{\"ok\":true,\"driven\":false}\n", "debug reply shape")
checkEqual(SocketReply.peer(uid: 501), "{\"ok\":true,\"uid\":501}\n", "peer reply carries the peer uid")
checkEqual(
    SocketReply.build(fingerprint: "abc123"),
    "{\"ok\":true,\"fingerprint\":\"abc123\"}\n",
    "build reply carries the fingerprint"
)
checkEqual(SocketReply.terminated("{\"ok\":true}"), "{\"ok\":true}\n", "terminated adds exactly one newline")

// --- 深链：turn 才带上 &turn=，非法 turn 丢弃 ---
checkEqual(
    JumpLink.url(base: "http://127.0.0.1:3080", sessionId: "abc", turn: 60),
    "http://127.0.0.1:3080/#dsh-notify-macos/session=abc&turn=60",
    "jump link carries the row anchor"
)
checkEqual(
    JumpLink.url(base: "http://127.0.0.1:3080", sessionId: "abc", turn: 0),
    "http://127.0.0.1:3080/#dsh-notify-macos/session=abc",
    "non-positive turn is dropped"
)

// --- 对端身份与准入策略（issue #32）---
// 这些是**安全不变量**，所以本地就钉住，不等 CI：
// 真实语义已用探针核对过 —— 非 socket fd 返回 ENOTSOCK(38)、非法/已关 fd 返回
// EBADF(9)，且失败时 out-param 不会被写成 0（否则会退化成"当成 root 放行"）。
func checkAccept(_ decision: PeerPolicy.Decision, _ label: String) {
    if case .accept = decision { check(true, label) } else { check(false, label) }
}
func checkReject(_ decision: PeerPolicy.Decision, _ label: String) {
    if case .reject = decision { check(true, label) } else { check(false, label) }
}

var peerPair: [Int32] = [-1, -1]
check(socketpair(AF_UNIX, SOCK_STREAM, 0, &peerPair) == 0, "socketpair works (peer check prerequisite)")
checkEqual(
    PeerIdentity.uid(ofSocket: peerPair[0]), UInt32(getuid()),
    "getpeereid returns the real peer uid (not a self-reported one)"
)
close(peerPair[0]); close(peerPair[1])
check(PeerIdentity.uid(ofSocket: -1) == nil, "invalid fd yields nil, never a uid of 0 (=root)")
checkAccept(PeerPolicy.decide(peerUid: UInt32(getuid()), daemonUid: UInt32(getuid())), "same uid is accepted")
checkAccept(PeerPolicy.decide(peerUid: 0, daemonUid: UInt32(getuid())), "root is accepted by design")
let strangerUid: UInt32 = UInt32(getuid()) == 999 ? 998 : 999
checkReject(PeerPolicy.decide(peerUid: strangerUid, daemonUid: UInt32(getuid())), "another user is rejected")

print(failures == 0 ? "CORE CHECK OK" : "CORE CHECK FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
