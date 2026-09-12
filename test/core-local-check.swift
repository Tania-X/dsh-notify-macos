// Core 自检（无需 XCTest）：把 dshNotifyCore 源码和这份脚本一起编译成可执行文件，
// 在本机跑一遍关键不变量。CI 上的 XCTest 仍是权威基线，这里只是把“只有 CI 才
// 能发现”的错误提前到本地 —— 例如快照夹具的日期格式（store 用 ISO8601 解码，
// 手写 `"time": 1` 会得到 .corrupt）。
//
//   test/core-local-check.sh
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

// --- 点击结果三态：只有 unconfirmed 才保留卡片 ---
check(JumpPolicy.shouldDismissCard(after: .visible), "visible outcome dismisses the card")
check(JumpPolicy.shouldDismissCard(after: .notApplicable), "notApplicable (no position jump) dismisses")
check(!JumpPolicy.shouldDismissCard(after: .unconfirmed), "unconfirmed keeps the card for a retry")
check(
    JumpPolicy.isVisibleToUser(navigated: true, browserIsFrontmost: false) == false,
    "navigated but browser not frontmost is NOT visible"
)
check(
    JumpPolicy.shouldEscalateActivation(browserIsFrontmost: false)
        && !JumpPolicy.shouldEscalateActivation(browserIsFrontmost: true),
    "activation escalates only when the browser did not come forward"
)

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

print(failures == 0 ? "CORE CHECK OK" : "CORE CHECK FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
