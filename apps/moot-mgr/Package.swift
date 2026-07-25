// swift-tools-version:6.2
//
// Package.swift — moot-mgr
//
// moot-mgr is the standalone observer/manager process for the MOOTx01
// telemetry pipeline (Manager 1.0, Phase 1 — the manager spine).
//
// What it is:
//   A PURE OBSERVER. It never hosts an estate DB. It owns the central
//   ObserverSink StatsStore (SQLite), the global monitoring on/off switch
//   (the flag row in the store), and the retention window. Consumers
//   (ARIA_MCP and other hosts) host their own estates and, when the flag is on,
//   write their dropbox rows directly into this store.
//
// What lives here:
//   MootManager (library)  — the manager core: store ownership, the on/off
//                            control, the retention loop, and the read/status
//                            surface. Testable without spawning a process.
//   moot-mgr (executable)  — the thin CLI entry point: parses the subcommand
//                            (monitoring on|off|status, retention run, status)
//                            and drives MootManager.
//
// This is an APP (peer to the ARIA surfaces). Swift is the PROTOTYPE / macOS
// build (this package). Post-prototype, BOTH a Swift (macOS) and a Rust
// (PC/Linux) version are on the roadmap — per parity-is-absolute, Swift-only
// is not the end state; the Rust/PC-Linux build serves the same web dashboard
// (concepts §9) and is sequenced after the mac binary is posted. The macOS
// menu-bar shell is a later phase (MANAGER_1.0_PLAN.md §5 Phase 5); Phase 1 is
// CLI only.
//
// Dependency hierarchy (no inversion — app depends on lib/kit, never reverse):
//   IntellectusLib (floor) → PersistenceKit (kit) → ObserverSink (lib) → moot-mgr (app)
//
// Dependency additions per in-repository dependency direction:
//   ObserverSink, IntellectusLib, PersistenceKit/PersistenceKitSQLite are
//   recorded as required updates in the change-impact analysis, citing
//   MANAGER_1.0_PLAN.md §1/§4. No external (third-party) Swift dependencies.
//
//   GeniusLocusKit + PersistenceKitInMemory added by cp-mootmgr-admin (P6 admin
//   plane): the resident host converges with the serve core to HOST and PROVISION
//   estates (MANAGER_1.0_PLAN.md §1, §4 P6). The admin plane invokes GLK's
//   provision / quiesce / drain / destroy / mountState surface (EstateProvision.swift
//   / EstateLifecycle.swift) to create and tear down real MOOTs through the
//   substrate — never a side-door DB file (concepts §1.8). InMemory is added so
//   the admin plane can provision volatile estates (GUI SPEC §4.2 flags InMemory
//   loudly). Recorded in the change-impact analysis.
//   Layering: moot-mgr is a top-level APP depending on a KIT (downstream→upstream)
//   — no inversion. No external (third-party) Swift dependencies are introduced.
//
// Platform floor: macOS 26 / iOS 26 (Tahoe) — matches the project-wide
// AI-capable OS floor and the ObserverSink/IntellectusLib/PersistenceKit floors.
// The package also builds on Linux Swift (no Apple-only API in the core).

import PackageDescription

let package = Package(
    name: "moot-mgr",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "MootManager", targets: ["MootManager"]),
        .executable(name: "moot-mgr", targets: ["moot-mgr"]),
    ],
    dependencies: [
        // ObserverSink: StatsStore (the central stats store), PersistenceStatsSink,
        // MetricRow/EventRow. The shared observer-sink reused by the manager.
        .package(name: "ObserverSink", path: "../../packages/libs/ObserverSink"),
        // IntellectusLib: Intellectus.setEnabled / StatSample / EventKind — used
        // by the integration-test consumer and the ARIA_MCP wiring.
        .package(name: "IntellectusLib", path: "../../packages/libs/IntellectusLib"),
        // PersistenceKit: Storage protocol, StorageIntrospection, StorageStats.
        // PersistenceKitSQLite: the SQLite backend behind the store (SQLite default,
        // MANAGER_1.0_PLAN.md §5 item 2). PersistenceKitInMemory: volatile backend
        // for admin-plane InMemory estates (cp-mootmgr-admin).
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
        // GeniusLocusKit: the composition layer the admin plane drives to provision
        // and tear down estates (provision/quiesce/drain/destroy/mountState).
        // cp-mootmgr-admin, MANAGER_1.0_PLAN.md §4 P6.
        .package(name: "GeniusLocusKit", path: "../../packages/kits/GeniusLocusKit"),
        // LoopbackHTTP: the shared zero-dependency loopback HTTP/1.1 server
        // (POSIXSocket + HTTPWire), extracted FROM this package in P1a so the
        // resident mootx01 MCP daemon and moot-mgr share one audited
        // loopback-bind implementation instead of two drifting copies. App→lib
        // (downstream→upstream), no inversion; LoopbackHTTP has zero deps.
        // Permitted per CLAUDE.md "Package.swift / Cargo.toml edits — controlled,
        // not forbidden"; bounded loopback HTTP.
        .package(name: "LoopbackHTTP", path: "../../packages/libs/LoopbackHTTP"),
        // LatticeLib: FDC (Frame-Directed Classification) runtime — surfaces
        // FDC.isAvailable, FDC.dataVersion, LatticeLib.version in the dashboard
        // Capabilities panel. dashboard dependency direction.
        .package(name: "LatticeLib", path: "../../packages/libs/LatticeLib"),
        // AriaLexiconLib: the reified ARIA grammar (Noun, Verb, Adjective,
        // Acceptance matrix) — used to serve the /api/lexicon endpoint as static
        // JSON. Zero runtime cost; compile-time enum iteration. dashboard dependency direction.
        .package(name: "AriaLexiconLib", path: "../../packages/libs/AriaLexiconLib"),
        // CognitionKit: shippedNeuronKitCapabilities — surfaces the set of
        // shipped NeuronKit capabilities in ServerPayload.capabilities, replacing
        // the hardcoded "pending Phase-2" dashboard row. dashboard dependency direction.
        .package(name: "CognitionKit", path: "../../packages/kits/CognitionKit"),
        // WorkPacketKit: durable agentic work-packet schema and drawer-backed store.
        // Used by PacketsEngine (GET /api/packets*) to surface exportable work packets.
        // FAB5-K1 Packets pane.
        .package(name: "WorkPacketKit", path: "../../packages/kits/WorkPacketKit"),
    ],
    targets: [
        // GenStaticAssets build-tool plugin: auto-regenerates StaticAssets.swift
        // from DashboardAssets/ before every build so the binary always serves
        // the latest assets. Applied to the MootManager target below.
        .plugin(
            name: "GenStaticAssets",
            capability: .buildTool(),
            path: "Plugins/GenStaticAssets"
        ),
        .target(
            name: "MootManager",
            dependencies: [
                .product(name: "ObserverSink", package: "ObserverSink"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LoopbackHTTP", package: "LoopbackHTTP"),
                .product(name: "LatticeLib", package: "LatticeLib"),
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "CognitionKit", package: "CognitionKit"),
                .product(name: "WorkPacketKit", package: "WorkPacketKit"),
            ],
            path: "Sources/MootManager",
            // DashboardAssets/ holds the EDITABLE source of the read-plane web UI
            // (index.html, app.css, app.js) plus the generator that embeds
            // them into StaticAssets.swift.
            // DashboardAssets/ is excluded — those files are not Swift sources.
            // StaticAssets.swift is excluded from the source tree here because the
            // GenStaticAssets plugin (prebuildCommand) generates a fresh copy into
            // the plugin work directory on every build, which SPM auto-compiles as
            // part of this target. The source-tree copy is kept in git as a reference
            // for the CI lint gate (make check-static-assets) but not compiled
            // directly — the plugin-generated copy is what goes into the binary.
            // SPM's sandbox prevents prebuildCommand from writing back to the source
            // tree, so the work-directory pattern is the correct sandbox-safe
            // approach for Swift 6.2.
            exclude: ["DashboardAssets", "StaticAssets.swift"],
            plugins: [.plugin(name: "GenStaticAssets")]
        ),
        .executableTarget(
            name: "moot-mgr",
            dependencies: [
                "MootManager",
            ],
            path: "Sources/moot-mgr"
        ),
        .testTarget(
            name: "MootManagerTests",
            dependencies: [
                "MootManager",
                .product(name: "ObserverSink", package: "ObserverSink"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "WorkPacketKit", package: "WorkPacketKit"),
            ],
            path: "Tests/MootManagerTests"
        ),
    ]
)
