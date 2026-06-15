// swift-tools-version:6.2
//
// ARIA_MCP — the local MCP server (stdio + loopback HTTP transports).
//
// ARIA_MCP exposes a GeniusLocusKit estate to any MCP client over local
// stdio or a resident loopback HTTP (Streamable-HTTP) transport. The wire is
// hand-rolled JSON-RPC 2.0 on the MemPalace server pattern (no MCP SDK
// dependency): a tool registry, a request dispatcher over initialize, ping,
// notifications, tools/list, and tools/call, and a read-write loop. Over stdio,
// stdout carries only JSON-RPC; all logging goes to stderr (ARIA_MCP_SPEC_v0.2
// §5). The HTTP transport (HTTPServer.swift) consumes the shared LoopbackHTTP
// lib and drives the same dispatcher.
//
// The tool surface is generated from AriaLexicon's verb-noun
// acceptance matrix (ARIA_MCP_SPEC_v0.2 §2): caller-surfaced verbs
// project as tools, action tools as verb_noun and the query tool
// (recall) as noun_verb. propose and associate are substrate-driven
// per AriaLexicon and surface as notifications, not tools (§4).
//
// Library + executable split: AriaMCP is the library so the test
// target can import and exercise the JSON-RPC dispatcher, the transports,
// and the estate-routing layer without spawning a process. aria-mcp is the
// thin executable entry point that opens an estate and runs the selected
// transport (stdio by default; HTTP when MOOTX01_HTTP_PORT is set).
//
// Platforms: macOS 15 / iOS 18 (Apple Silicon), per CLAUDE.md.

import PackageDescription

let package = Package(
    name: "AriaMcpKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "AriaMCP", targets: ["AriaMCP"]),
        // AriaResident: the resident-daemon composition layer (telemetry + Brain
        // pump + monitoring gate + HTTP transport), shared by both the product
        // binary (mootx01 serve) and aria-mcp so the resident wiring exists once.
        // Sits ABOVE the telemetry-free AriaMCP core (ADR-LOOPBACKHTTP-001).
        .library(name: "AriaResident", targets: ["AriaResident"]),
    ],
    dependencies: [
        .package(name: "AriaLexiconLib", path: "../../libs/AriaLexiconLib"),
        .package(name: "GeniusLocusKit", path: "../GeniusLocusKit"),
        .package(name: "NeuronKit", path: "../NeuronKit"),
        // SubstrateML provides ARM (MiningThresholds) and FCA (BoundedConceptMiner,
        // FormalAttribute, FormalContext) types consumed by LensTools.swift.
        // These engines were relocated from NeuronKit in MX-0a (ARM) and MX-0B (FCA).
        .package(name: "SubstrateML", path: "../../libs/SubstrateML"),
        .package(name: "CognitionKit", path: "../CognitionKit"),
        .package(name: "LocusKit", path: "../LocusKit"),
        // CorpusKit + VectorKit: the aria-mcp executable wires semantic recall
        // for the durable SQLite estate (ARIA_MCP_SQLITE_PATH) by constructing a
        // Corpus + VectorStore after `kit.open` and registering both — the same
        // composition EstateLifecycle.provision wires for a .glk estate. Without
        // this, the BM25 + vector recall lanes stay dark on a bare open. App →
        // kit layering (downstream→upstream), no inversion. Permitted per
        // DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        .package(name: "CorpusKit", path: "../CorpusKit"),
        .package(name: "VectorKit", path: "../VectorKit"),
        // SubstrateTypes provides RowVerb, consumed by HTTPServer.swift's
        // tombstone-instant resolution (audit-trail fallback) after the
        // topology-analysis relocation to NeuronKit. App → lib layering, no
        // inversion. Permitted per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        .package(name: "SubstrateTypes", path: "../../libs/SubstrateTypes"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // VaultKit: the moot_vault_* tool family consumes VaultBridge.
        // In-repo dependency, permitted per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28
        // and recorded in ADR-VAULTKIT-002. Layering is downstream→upstream
        // (ARIA_MCP app → VaultKit kit); no inversion.
        .package(name: "VaultKit", path: "../VaultKit"),
        // ObserverSink + IntellectusLib: the manager-telemetry pipeline. The
        // aria-mcp executable (NOT the AriaMCP library) installs a
        // PersistenceStatsSink against the manager's stats store and drives
        // Intellectus.setEnabled from the store flag, so the headless ARIA
        // deployment self-reports when the manager turns monitoring on. App →
        // lib layering, no inversion. The telemetry pipeline is specified in
        // docs/reference/MOOT_MGR_SPEC.md.
        .package(name: "ObserverSink", path: "../../libs/ObserverSink"),
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
        // LoopbackHTTP: the shared zero-dependency loopback HTTP/1.1 server that
        // backs the resident HTTP MCP transport (HTTPServer.swift). App→lib
        // (downstream→upstream), no inversion; LoopbackHTTP has zero deps.
        // Permitted per CLAUDE.md "Package.swift / Cargo.toml edits — controlled,
        // not forbidden"; ADR-LOOPBACKHTTP-001.
        .package(name: "LoopbackHTTP", path: "../../libs/LoopbackHTTP"),
        // LatticeLib: the resident Autonomic Governor drives PoolReducer.reduce on
        // a low cadence (novel-token merge-back — the second dormant learning
        // loop). App→lib layering (downstream→upstream), no inversion; LatticeLib
        // is a packages/libs package. Permitted per CLAUDE.md "Package.swift /
        // Cargo.toml edits — controlled, not forbidden"
        // (DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28).
        .package(name: "LatticeLib", path: "../../libs/LatticeLib"),
        // ConvergenceKit: EstateStatusSyncTests import NoSyncEngine (ConvergenceKitNone)
        // to force-test the OP-1 honest sync vocabulary. The AriaMCP library reaches
        // sync state through GeniusLocusKit.syncStateToken — ConvergenceKit is a test-only
        // dep here. App → kit layering (downstream→upstream), no inversion.
        // Per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        .package(name: "ConvergenceKit", path: "../ConvergenceKit"),
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
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "VaultKit", package: "VaultKit"),
                // LatticeLib backs the governor's PoolReducer.reduce trigger
                // (AutonomicGovernor.swift): the low-cadence novel-token merge-back.
                .product(name: "LatticeLib", package: "LatticeLib"),
                // LoopbackHTTP backs HTTPServer.swift (the resident HTTP MCP transport).
                .product(name: "LoopbackHTTP", package: "LoopbackHTTP"),
            ],
            path: "Sources/AriaMCP"
        ),
        .target(
            name: "AriaResident",
            dependencies: [
                "AriaMCP",
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                // Telemetry lives HERE (the composition layer), not in AriaMCP —
                // keeping the JSON-RPC core free of ObserverSink/IntellectusLib.
                .product(name: "ObserverSink", package: "ObserverSink"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Sources/AriaResident"
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
                // CorpusKit + VectorKit: DurableSemanticRecallTests builds the same
                // Corpus + VectorStore the aria-mcp durable branch wires, to assert
                // the BM25/vector lanes light up and survive a restart.
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "VectorKit", package: "VectorKit"),
                .product(name: "VaultKit", package: "VaultKit"),
                // LoopbackHTTP: HTTPServerTests drive the HTTP transport directly.
                .product(name: "LoopbackHTTP", package: "LoopbackHTTP"),
                // ConvergenceKit + ConvergenceKitNone: EstateStatusSyncTests exercises
                // the OP-1 honest sync vocabulary using NoSyncEngine (disabled / enabled)
                // to assert the fabricated "status: connected" literal is gone and the
                // canonical vocabulary is reported correctly.
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                .product(name: "ConvergenceKitNone", package: "ConvergenceKit"),
                // SubstrateTypes: FactTimelineLifecycleTagTests assert the
                // fact_timeline lifecycle tag against the canonical
                // RowState.cluster classifier (the substrate primitive the
                // runner now derives the active/retired partition from).
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
            ],
            path: "Tests/AriaMCPTests"
        ),
        .testTarget(
            name: "AriaResidentTests",
            dependencies: [
                "AriaResident",
                .product(name: "ObserverSink", package: "ObserverSink"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Tests/AriaResidentTests"
        ),
    ]
)
