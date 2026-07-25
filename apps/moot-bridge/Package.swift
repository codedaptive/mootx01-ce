// swift-tools-version:6.2
import PackageDescription

// moot-bridge — a bridging MCP memory server.
//
// An AI client launches THIS process as its single memory MCP server. The bridge
// then fans every WRITE out to BOTH configured backends (MemPalace AND mootx01)
// and serves every READ from whichever backend is currently PRIMARY. The AI can
// flip the primary mid-session with a single bridge-owned tool call
// (`bridge_set_primary`), no restart required.
//
// Zero EXTERNAL (third-party) dependencies — the hard MOOTx01 standard. Config
// is JSON, decoded via Foundation Codable (no YAML parser). The two in-repo
// library deps are the same ones the mcp-benchmarker takes, for the same reason:
// the bridge emits its real per-backend latency + failure-count metrics through
// IntellectusLib into ObserverSink's PersistenceStatsSink (the `--stats-store`
// option), so moot-mgr can dashboard a live bridge session. These are in-repo libs
// only; layering is correct (this tool is downstream of both libs). No external
// deps added. (Permitted per in-repository dependency direction; the
// dependency is recorded as MUST_UPDATE in the lane blast-radius notes.)
//
// Platform floor: macOS 26 (Tahoe) / swift-tools 6.2 — matches the
// IntellectusLib / ObserverSink floors this tool depends on, and the
// project-wide AI-capable OS floor.
let package = Package(
    name: "moot-bridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "moot-bridge", targets: ["moot-bridge"]),
    ],
    dependencies: [
        .package(path: "../../packages/libs/IntellectusLib"),
        .package(path: "../../packages/libs/ObserverSink"),
    ],
    targets: [
        .executableTarget(
            name: "moot-bridge",
            dependencies: [
                "IntellectusLib",
                "ObserverSink",
            ],
            path: "Sources/moot-bridge"
        ),
        .testTarget(
            name: "moot-bridgeTests",
            dependencies: ["moot-bridge"],
            path: "Tests/moot-bridgeTests"
        ),
    ]
)
