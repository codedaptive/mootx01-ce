// swift-tools-version:6.2
//
// Installer — the mootx01 unified CLI binary.
//
// Ships a single `mootx01` binary that serves, installs, uninstalls,
// manages named estate databases, and issues queries. The binary
// replaces the prior two-binary arrangement (mootx01-mcp stdio server +
// bash install scripts) per MOOTX01-CLI-001.
//
// The serve subcommand wraps AriaMCP + GeniusLocusKit on macOS only
// (Apple Silicon, macOS 26+). All other subcommands — install, uninstall,
// db, status, query — are cross-platform and compile on Linux.
//
// MootInstallerCore holds path/config helpers and the installer state
// machine. The test target exercises those helpers without spawning a
// process or touching real user data.
//
// Binary name: mootx01 (replaces mootx01-mcp; all client configs use
// the new name after running `mootx01 install`).

import PackageDescription

let package = Package(
    name: "mootx01",
    // macOS(.v26) is the package-level minimum; serve and its deps
    // (AriaMCP, GeniusLocusKit, LocusKit, PersistenceKitSQLite) require it.
    // Linux builds succeed because ServeCommand.swift is guarded with
    // #if os(macOS) — SPM compiles only the cross-platform subcommands
    // (install, uninstall, db, status, query) on Linux.
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MootInstallerCore", targets: ["MootInstallerCore"]),
        .executable(name: "mootx01", targets: ["mootx01"]),
        // MACD-2c1: the edition-neutral shared signed-provider substrate.
        // Exported as a library product so the Xcode-side sandboxed helper
        // shell (Mootx01-DaemonProviderHelper-macOS, defined in
        // apps/Mootx01-App/project.yml) links the IDENTICAL module the direct
        // shell below links — the mission's "parallel copies fail" rule is
        // enforced by there being exactly one module to link.
        .library(name: "MootDaemonProvider", targets: ["MootDaemonProvider"]),
        // MACD-2c1: the thin direct app-like daemon shell. One source file;
        // all behavior lives in MootDaemonProvider so both shells compile the
        // same substance (Kong K2 structural digest identity).
        .executable(name: "mootx01-daemon", targets: ["mootx01-daemon"]),
        // F3: dedicated headless contract-test host. Spawned by ContractDaemonHarness
        // instead of mootx01-daemon so the production binary contains no env-var bypass
        // paths that skip activate() / provider lock / Keychain custody. Uses the same
        // CommunityResidentMain.makeCommunityDispatch function as production (F2).
        .executable(name: "mootx01-daemon-contract-host", targets: ["mootx01-daemon-contract-host"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "AriaLexiconLib", path: "../../packages/libs/AriaLexiconLib"),
        .package(
            name: "GeniusLocusKit",
            path: "../../packages/kits/GeniusLocusKit",
            traits: ["MigrationFloor1_0"]
        ),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        // VaultKit: UpgradeCommand injects DrawerMapping.lineageID into the
        // LocusKit kg_facts identity backfill (MXE-MI). The resolver is
        // injected at the app layer because LocusKit sits below VaultKit
        // and must not import it.
        .package(name: "VaultKit", path: "../../packages/kits/VaultKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
        // EstateEncryption: the plaintext-to-encrypted estate conversion, in its
        // own library so the product and the benchmark harness share one
        // implementation and one Rust twin.
        .package(name: "EstateEncryption", path: "../../packages/libs/EstateEncryption"),
        .package(name: "AriaMcpKit", path: "../../packages/kits/AriaMcpKit"),
        // NeuronKit: DreamCommand constructs DreamingDaemon + seam adapters
        // (EstateDreamingReader, EstateDreamingSink, EstateManifestDreamingPolicyStore)
        // to run one REM-ALPHA dreaming cycle. Required for the dreaming path.
        .package(name: "NeuronKit", path: "../../packages/kits/NeuronKit"),
        // QueueKit: DreamCommand acquires the "dreaming" DrainLease to prevent
        // concurrent dreamers for the same estate. Required for the dreaming path.
        .package(name: "QueueKit", path: "../../packages/kits/QueueKit"),
    ],
    targets: [
        .target(
            name: "MootInstallerCore",
            // Two dependencies, each for exactly one reason — do not grow
            // this list with domain logic.
            //
            // PersistenceKitSQLite: EstateKeyProvider must go through
            // KeychainKeyStore rather than reimplement key custody. A second
            // implementation could derive a different Keychain account and
            // mint a second key for the same estate, which is an
            // unopenable-estate bug, so the real store is the only
            // acceptable path.
            //
            // EstateEncryption: the plaintext→encrypted conversion
            // (CE-1.0.35-08). This module keeps only the two app-layer seams —
            // the launchd daemon control and the EstateKeyProvider spelling of
            // file-state detection — and re-exports the rest.
            dependencies: [
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "EstateEncryption", package: "EstateEncryption"),
            ],
            path: "Sources/MootInstallerCore"
        ),
        .executableTarget(
            name: "mootx01",
            dependencies: [
                "MootInstallerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // macOS-only: serve subcommand depends on the MCP stack + GLK.
                // On Linux these products are unavailable; ServeCommand.swift uses
                // #if os(macOS) guards so the Linux build omits the serve subcommand.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // AriaResident: the shared resident-daemon runner (HTTP transport +
                // autonomic governor + telemetry/monitoring gate). `mootx01 serve` calls it
                // when resident (MOOTX01_HTTP_PORT/--http) so the product binary and
                // aria-mcp run identical resident wiring.
                .product(name: "AriaResident", package: "AriaMcpKit"),
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "GeniusLocusKitMigrations", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                // VaultKit: DrawerMapping resolver for the kg_facts identity
                // backfill run by `mootx01 upgrade` (MXE-MI).
                .product(name: "VaultKit", package: "VaultKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // ServeCommand's MOOTX01_BACKEND=inmemory path constructs
                // InMemoryStorage directly (accuracy-measurement posture,
                // no filesystem in the measurement path). The module was
                // resolving transitively before this declaration; this
                // makes the dependency explicit rather than accidental.
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // DreamCommand: NeuronKit provides DreamingDaemon + seam adapters;
                // QueueKit provides DrainLease for per-stream stampede prevention.
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Sources/mootx01"
        ),
        // MACD-2c1: shared signed-provider substrate. Depends on AriaMCP for
        // exactly one reason — it IS the frozen first-party contract home
        // (FirstPartyAuthProtocol, FirstPartyDescriptor, CanonicalEncoder,
        // FirstPartyAuthServer seams). The provider consumes that contract
        // through its existing public API only; a third copy of the algebra
        // is forbidden (MACD-2b "parallel copies fail"). The AriaMcpKit
        // package dependency already exists at package level for ServeCommand.
        .target(
            name: "MootDaemonProvider",
            dependencies: [
                .product(name: "AriaMCP", package: "AriaMcpKit"),
            ],
            path: "Sources/MootDaemonProvider"
        ),
        // MACD-2c1: the thin daemon shell. Deliberately name-adjacent to the
        // LaunchAgent service label com.mootx01.daemon (MootInstallerCore
        // Paths/LaunchAgent, untouched here): c2's installer convergence
        // binds this binary behind that label without a rename. The target
        // contains one thin main.swift; the Xcode helper target compiles the
        // SAME directory.
        // Wave A1b: MootCommunityDaemon added so main.swift can pass
        // CommunityResidentMain.run as the residentActivate closure to
        // DaemonShellMain.run(arguments:residentActivate:).
        .executableTarget(
            name: "mootx01-daemon",
            dependencies: ["MootDaemonProvider", "MootCommunityDaemon"],
            path: "Sources/mootx01-daemon"
        ),
        // F3: dedicated headless contract-test host.
        //
        // Spawned by ContractDaemonHarness in place of mootx01-daemon, so the
        // production binary contains NO env-var branches that skip activate() /
        // provider lock / Keychain custody.
        //
        // This binary calls CommunityResidentMain.makeCommunityDispatch (from
        // MootCommunityDaemon) with plaintext keys and slow poll intervals —
        // the SAME shared composition function the production daemon calls. Using
        // one function for both paths means the harness certifies the coordinator
        // composition that actually runs in production (F2 + F3 together).
        .executableTarget(
            name: "mootx01-daemon-contract-host",
            dependencies: [
                "MootDaemonProvider",
                "MootCommunityDaemon",
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
            ],
            path: "Sources/mootx01-daemon-contract-host"
        ),
        // Wave A1a: production estate-lifecycle conformers for the CE daemon.
        // Depends on MootDaemonProvider for the EstateLifecycleAuthority and
        // SourceEstateAccess protocols; on LocusKit + PersistenceKitSQLite for
        // the real estate stack; and on SQLCipher for the raw C API needed by
        // CommunitySourceEstateAccess (openExclusive, checkpointTruncate,
        // verifyReadOnlyOpen). MootDaemonProvider's package graph is deliberately
        // frozen (only AriaMCP); all estate-stack imports live here.
        .target(
            name: "MootCommunityDaemon",
            dependencies: [
                "MootDaemonProvider",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // SQLCipher: CommunitySourceEstateAccess uses sqlite3_open_v2,
                // sqlite3_exec, sqlite3_wal_checkpoint_v2, sqlite3_prepare_v2,
                // and sqlite3_column_text directly for exclusive open, WAL
                // truncation, and identity reads — operations not exposed through
                // the SQLiteStorage public API. The product is exported from the
                // PersistenceKit package, so no new package-level dep is required.
                .product(name: "SQLCipher", package: "PersistenceKit"),
                // Wave A1b: CommunityContractDispatch conforms to CommunityToolHandler
                // (defined in AriaMCP), and CommunityResidentMain constructs
                // ARIA_MCPDispatcher + HTTPServer + FirstPartyAuthServer directly.
                // All three types are AriaMCP surfaces; no new package-level dep
                // is required — AriaMcpKit already exists at package level.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // Wave C1 (CORE-06): CommunityObsidianCoordinator wraps
                // VaultResidentService + VaultWatcher from VaultKit, which requires
                // GeniusLocusKit. No new package-level dependency — both packages
                // already declared above.
                .product(name: "VaultKit", package: "VaultKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
            ],
            path: "Sources/MootCommunityDaemon"
        ),
        .testTarget(
            name: "MootDaemonProviderTests",
            dependencies: ["MootDaemonProvider"],
            path: "Tests/MootDaemonProviderTests"
        ),
        // Wave A1a: tests for the community-daemon estate conformers.
        // Wave A1b: adds CommunityContractTests (digest honesty, dispatch, auth).
        // LocusKitEstateFixture provides the twenty-row plaintext estate
        // for tests that need a real on-disk estate (NEVER the production estate).
        // Wave C1 (CORE-06): adds CommunityObsidianTests — real temp estates +
        // temp vault dirs, GeniusLocusKit (in-memory), VaultKit types.
        .testTarget(
            name: "MootCommunityDaemonTests",
            dependencies: [
                "MootCommunityDaemon",
                "MootDaemonProvider",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "LocusKitEstateFixture", package: "LocusKit"),
                // Wave A1b: CommunityContractTests constructs FirstPartyAuthServer
                // and ARIA_MCPDispatcher directly for in-process stack tests.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // Wave C1: obsidian tests use GeniusLocusKit + in-memory estates.
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "VaultKit", package: "VaultKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/MootCommunityDaemonTests"
        ),
        .testTarget(
            name: "MootInstallerCoreTests",
            dependencies: [
                "MootInstallerCore",
                // The twenty-row plaintext estate fixture (CE-1.0.35-04). Test
                // support only: detection has to be proven against a REAL estate
                // file, and the production estate is never an acceptable target.
                .product(name: "LocusKitEstateFixture", package: "LocusKit"),
            ],
            path: "Tests/MootInstallerCoreTests"
        ),
        // CORE-10: headless contract conformance harness.
        //
        // Spawns a REAL mootx01-daemon subprocess in headless mode (env-var
        // override selecting a temp estate root and a fixed test auth root) and
        // runs the full 60-case fixture suite against it over real HTTP.  No
        // fixture playback: every response comes from the live dispatcher.
        //
        // The three support files (ContractDaemonHarness, ShapeValidator,
        // BundleDigest) pre-exist in the Tests/MootCommunityContractTests
        // directory from prior exploration work; this target declaration makes
        // them part of the build.
        .testTarget(
            name: "MootCommunityContractTests",
            dependencies: [
                "MootDaemonProvider",
                .product(name: "AriaMCP", package: "AriaMcpKit"),
            ],
            path: "Tests/MootCommunityContractTests"
        ),
    ]
)
