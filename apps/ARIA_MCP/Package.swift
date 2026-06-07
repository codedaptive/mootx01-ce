// swift-tools-version:6.2
//
// ARIA_MCP — the local stdio MCP server.
//
// ARIA_MCP exposes a GeniusLocusKit estate to any MCP client over
// local stdio. The wire is hand-rolled JSON-RPC 2.0 on the MemPalace
// server pattern (no MCP SDK dependency): a tool registry, a request
// dispatcher over initialize, ping, notifications, tools/list, and
// tools/call, and a read-write loop. stdout carries only JSON-RPC;
// all logging goes to stderr (ARIA_MCP_SPEC_v0.2 §5).
//
// The tool surface is generated from AriaLexicon's verb-noun
// acceptance matrix (ARIA_MCP_SPEC_v0.2 §2): caller-surfaced verbs
// project as tools, action tools as verb_noun and the query tool
// (recall) as noun_verb. propose and associate are substrate-driven
// per AriaLexicon and surface as notifications, not tools (§4).
//
// Library + executable split: AriaMCP is the library so the test
// target can import and exercise the JSON-RPC dispatcher and the
// estate-routing layer without spawning a process. aria-mcp is the
// thin executable entry point that opens an estate and runs the
// stdio loop.
//
// Platforms: macOS 15 / iOS 18 (Apple Silicon), per CLAUDE.md.

import PackageDescription

let package = Package(
    name: "ARIA_MCP",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "AriaMCP", targets: ["AriaMCP"]),
        .executable(name: "aria-mcp", targets: ["aria-mcp"]),
    ],
    dependencies: [
        .package(name: "AriaLexiconLib", path: "../../packages/libs/AriaLexiconLib"),
        .package(name: "GeniusLocusKit", path: "../../packages/kits/GeniusLocusKit"),
        .package(name: "NeuronKit", path: "../../packages/kits/NeuronKit"),
        // SubstrateML provides ARM (MiningThresholds) and FCA (BoundedConceptMiner,
        // FormalAttribute, FormalContext) types consumed by LensTools.swift.
        // These engines were relocated from NeuronKit in MX-0a (ARM) and MX-0B (FCA).
        .package(name: "SubstrateML", path: "../../packages/libs/SubstrateML"),
        .package(name: "CognitionKit", path: "../../packages/kits/CognitionKit"),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
        // VaultKit: the moot_vault_* tool family consumes VaultBridge.
        // In-repo dependency, permitted per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28
        // and recorded in ADR-VAULTKIT-002. Layering is downstream→upstream
        // (ARIA_MCP app → VaultKit kit); no inversion.
        .package(name: "VaultKit", path: "../../packages/kits/VaultKit"),
        // ObserverSink + IntellectusLib: the manager-telemetry pipeline. The
        // aria-mcp executable (NOT the AriaMCP library) installs a
        // PersistenceStatsSink against the manager's stats store and drives
        // Intellectus.setEnabled from the store flag, so the headless ARIA
        // deployment self-reports when the manager turns monitoring on. App →
        // lib layering, no inversion.
        .package(name: "ObserverSink", path: "../../packages/libs/ObserverSink"),
        .package(name: "IntellectusLib", path: "../../packages/libs/IntellectusLib"),
    ],
    targets: [
        .target(
            name: "AriaMCP",
            dependencies: [
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "CognitionKit", package: "CognitionKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                .product(name: "VaultKit", package: "VaultKit"),
            ],
            path: "Sources/AriaMCP"
        ),
        .executableTarget(
            name: "aria-mcp",
            dependencies: [
                "AriaMCP",
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // SQLite backend: selected at runtime via ARIA_MCP_SQLITE_PATH.
                // Present and non-empty → SQLiteStorage; absent/empty → InMemoryStorage.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // PostgreSQL backend: selected at runtime via ARIA_MCP_POSTGRES_URL.
                // Both ARIA_MCP_POSTGRES_URL and ARIA_MCP_SQLITE_PATH set → exit 1.
                // Only ARIA_MCP_POSTGRES_URL set → PostgreSQLStorage (lazy pool).
                .product(name: "PersistenceKitPostgreSQL", package: "PersistenceKit"),
                // Manager-telemetry self-report wiring (executable-only — the
                // JSON-RPC library surface is untouched). Installs a
                // PersistenceStatsSink against the manager's store when
                // ARIA_MCP_STATS_STORE is set; silent no-op otherwise.
                .product(name: "ObserverSink", package: "ObserverSink"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Sources/aria-mcp"
        ),
        .testTarget(
            name: "AriaMCPTests",
            dependencies: [
                "AriaMCP",
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "CognitionKit", package: "CognitionKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // SQLite backend: needed for the persistence round-trip tests.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // PostgreSQL backend: needed for the precedence-ladder config tests.
                .product(name: "PersistenceKitPostgreSQL", package: "PersistenceKit"),
                .product(name: "VaultKit", package: "VaultKit"),
            ],
            path: "Tests/AriaMCPTests"
        ),
    ]
)
