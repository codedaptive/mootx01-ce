// swift-tools-version:6.2
//
// aria-mcp-server — the standalone reference MCP server (stdio + loopback HTTP).
//
// The thin executable entry point that opens an estate and runs the selected
// transport (stdio by default; HTTP when MOOTX01_HTTP_PORT is set). All server
// logic lives in AriaMcpKit (the AriaMCP library + AriaResident composition
// layer); this package is just the `aria-mcp` binary that wires them together.
// It is the dev/reference server — the same runtime `mootx01 serve` runs by
// linking AriaResident directly. The Apple app (apps/Mootx01-App) launches this
// binary as a managed external server to prove the substrate is shared.
//
// Platforms: macOS 26 / iOS 26 (Apple Silicon), per CLAUDE.md.

import PackageDescription

let package = Package(
    name: "aria-mcp-server",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .executable(name: "aria-mcp", targets: ["aria-mcp"]),
    ],
    dependencies: [
        .package(name: "AriaMcpKit", path: "../../packages/kits/AriaMcpKit"),
        .package(
            name: "GeniusLocusKit",
            path: "../../packages/kits/GeniusLocusKit",
            traits: ["MigrationFloor1_0"]
        ),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
        .package(name: "CorpusKit", path: "../../packages/kits/CorpusKit"),
        .package(name: "VectorKit", path: "../../packages/kits/VectorKit"),
    ],
    targets: [
        .executableTarget(
            name: "aria-mcp",
            dependencies: [
                // The server logic + resident-daemon composition (AriaMcpKit).
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "AriaResident", package: "AriaMcpKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "GeniusLocusKitMigrations", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // SQLite backend: selected at runtime via ARIA_MCP_SQLITE_PATH.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // PostgreSQL backend: selected at runtime via ARIA_MCP_POSTGRES_URL.
                .product(name: "PersistenceKitPostgreSQL", package: "PersistenceKit"),
                // Semantic recall wiring for the durable SQLite estate (BM25 + vector).
                .product(name: "CorpusKit", package: "CorpusKit"),
                // CorpusKitProviders: the concrete five-signal ensemble
                // (CorpusEnsemble.defaultEnsemble()) the server wires into Lane D.
                // Dependency per in-repository dependency direction; the
                // server is downstream of the providers, no layering inversion.
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "VectorKit", package: "VectorKit"),
            ],
            path: "Sources/aria-mcp"
        ),
    ]
)
