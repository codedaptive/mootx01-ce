// swift-tools-version:6.2
import PackageDescription

// Standalone benchmarking tool. JSON config decodes via Foundation Codable —
// no YAML parser needed. The tool speaks the MCP wire protocol to the two
// servers it benchmarks; it imports no MOOTx01 kit at the MCP boundary.
// External dependency: `swift-subprocess` (for stdio process management).
//
// In-repo library dependencies are recorded as MUST_UPDATE in
// BENCHMARKER_001_BLAST_RADIUS.md: the benchmarker
// emits its real metrics through IntellectusLib into ObserverSink's
// PersistenceStatsSink (the `--stats-store` option). Layering is correct
// (the tool is downstream of both libs).
//
// Platform floor: macOS 26 (Tahoe) / swift-tools 6.2 — matches the
// IntellectusLib / ObserverSink floors this tool now depends on, and the
// project-wide AI-capable OS floor.
//
// CE path note: this package lives at apps/mcp-benchmarker/ (not inside a
// swift-bench/ subdirectory as in EE). Package-relative paths are adjusted
// accordingly: ../../packages/libs/ (two levels up from apps/mcp-benchmarker/).
let package = Package(
    name: "mcp-benchmarker",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "mcp-benchmarker", targets: ["mcp-benchmarker"]),
    ],
    dependencies: [
        .package(path: "../../packages/libs/IntellectusLib"),
        .package(path: "../../packages/libs/ObserverSink"),
        // Apple's Subprocess package — the supported way to drive a child
        // process's stdio. Foundation's Process+Pipe+FileHandle path carries a
        // documented ~150-200ms per-call read-wakeup latency on macOS that
        // falsified the gauntlet's per-call latency measurement; Apple's own
        // guidance (Developer Forums 690310) is to adopt Subprocess. This is a
        // TOOL dependency only — no kit takes it; the kit zero-external-dep
        // rule is unaffected.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-benchmarker",
            dependencies: [
                "IntellectusLib",
                "ObserverSink",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            path: "Sources/mcp-benchmarker"
        ),
        .testTarget(
            name: "mcp-benchmarkerTests",
            dependencies: ["mcp-benchmarker"],
            path: "Tests/mcp-benchmarkerTests"
        ),
    ]
)
