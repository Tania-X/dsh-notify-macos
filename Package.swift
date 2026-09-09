// swift-tools-version: 5.9
//
// dsh-notify-macos daemon — SwiftPM layout (see docs/l2-swiftpm-split.md).
//   dshNotifyServer : AppKit executable (window shell, drawing, browser jump)
//   dshNotifyCore   : Foundation-only library (CardModel state machine,
//                     ShowRequest parsing, OutcomeKind, jump policy) — the
//                     unit-testable core (Tests/dshNotifyCoreTests).
//
// Build:  swift build -c release
// Binary: .build/release/dsh-notify-server  (copied to bin/ by scripts)
import PackageDescription

let package = Package(
    name: "dsh-notify-macos-daemon",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "dsh-notify-server", targets: ["dshNotifyServer"]),
    ],
    targets: [
        .target(name: "dshNotifyCore"),
        .executableTarget(
            name: "dshNotifyServer",
            dependencies: ["dshNotifyCore"]
        ),
        .testTarget(
            name: "dshNotifyCoreTests",
            dependencies: ["dshNotifyCore"]
        ),
    ]
)
