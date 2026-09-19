// swift-tools-version:6.2
//
// Community Edition manifest — the mootx01 unified CLI binary (CE subset).
//
// This file is the authoritative CE package declaration for apps/mootx01.
// It is maintained by EE and published to CE through the edition publication
// contract; CE never receives Package.swift directly (that file is
// EDITION-SURFACE — each edition owns its copy).
//
// WHAT IS EXCLUDED vs Package.swift (Kong ruling 3002C59F / MACD-3D):
//   • MootDaemonFederation target   — federation is a Pro/EE surface
//   • MootDaemonFederationTests     — ships with MootDaemonFederation above
//   • MootProductDock target/tests  — authenticated Pro product attachment
//   • ConvergenceKit dependency     — the sync backend package (EE dependency)
//   • Any CloudKit-dependent target — APNs/CloudKit entitlement is EE-only
//
// WHY: federation and sync are Pro/EE capabilities. The Community daemon ships
// the shared signed-provider substrate (MootDaemonProvider) and the standard
// CLI tooling, but it does not run federation sync sessions. Adding those
// surfaces to CE would publish unreviewed Pro behaviour and would require
// entitlements and server-side infrastructure that CE does not have.
//
// Maintainer note: when Package.swift gains a new SHARED target, add it here
// too. When Package.swift gains a federation/sync target, do NOT add it here.
// The intentional divergences from Package.swift are:
//   • MootDaemonFederation, MootDaemonFederationTests (federation is EE-only)
//   • MootProductDock, MootProductDockTests (authenticated Pro attachment, EE-only)
//   • ConvergenceKit package (the sync backend; its only CE consumer was removed)
// All other targets, packages, and settings must stay in parity with Package.swift.
//
// Binary name: mootx01 (replaces mootx01-mcp; all client configs use
// the new name after running `mootx01 install`).

import PackageDescription

let package = Package(
    name: "mootx01",
    // macOS 27 is the product floor. Apple Foundation Models fact extraction
    // is a mandatory Apple build dependency, not a runtime-optional package.
    // Linux builds succeed because ServeCommand.swift is guarded with
    // #if os(macOS) — SPM compiles only the cross-platform subcommands
    // (install, uninstall, db, status, query) on Linux.
    platforms: [
        .macOS("27.0"),
        // iOS(.v27) was added by MACD-3B4 to prevent SPM from inferring iOS 15.0
        // when Mootx01-App linked MootDaemonProvider for iOS.  MACD-3B5 made the
        // Mootx01-App → MootDaemonProvider dependency macOS-conditional, so iOS no
        // longer depends on this package at all; the floor entry is removed.
        // MootDaemonProvider is a macOS-only artifact (SecCode/ServiceManagement);
        // iOS is embedded-only per MACD-3a EstatePlatformCapability.embeddedOnly.
    ],
    products: [
        // The estate-open funnel shared by all command targets.
        .library(name: "MootEstateOpen", targets: ["MootEstateOpen"]),
        .library(name: "MootInstallerCore", targets: ["MootInstallerCore"]),
        .executable(name: "mootx01", targets: ["mootx01"]),
        // MACD-2c1: the edition-neutral shared signed-provider substrate.
        // Exported as a library product so the Xcode-side sandboxed helper
        // shell (Mootx01-DaemonProviderHelper-macOS, defined in
        // apps/Mootx01-App/project.yml) links the IDENTICAL module the direct
        // shell below links — the mission's "parallel copies fail" rule is
        // enforced by there being exactly one module to link.
        .library(name: "MootDaemonProvider", targets: ["MootDaemonProvider"]),
        // Shared Community resident composition, exported for the signed
        // sandboxed daemon-helper target in the Apple project.
        .library(name: "MootCommunityDaemon", targets: ["MootCommunityDaemon"]),
        // MACD-2c1: the thin direct app-like daemon shell. One source file;
        // all behavior lives in MootDaemonProvider so both shells compile the
        // same substance (Kong K2 structural digest identity).
        .executable(name: "mootx01-daemon", targets: ["mootx01-daemon"]),
        // Dedicated headless contract-test host. It composes the same Community
        // coordinators as production without adding any EE capability.
        .executable(name: "mootx01-daemon-contract-host", targets: ["mootx01-daemon-contract-host"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "AriaLexiconLib", path: "../../packages/libs/AriaLexiconLib"),
        .package(
            name: "GeniusLocusKit",
            path: "../../packages/kits/GeniusLocusKit",
            traits: ["MigrationFloor1_0", "CrossEncoder"]
        ),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "FactExtractionKit", path: "../../packages/kits/FactExtractionKit"),
        // SynapseKit + SubstrateKernel: the span-encode and vector-reclaim
        // steps of `mootx01 upgrade` write encoder span rows
        // (VectorStore.writeSpanVectors, Int8Vec.quantize) and reclaim the
        // retired dense-family rows (VectorStore.reclaimRetiredVectorRows).
        // Both were resolving transitively through GeniusLocusKit; naming
        // them keeps the upgrade wiring explicit and removable.
        .package(name: "SynapseKit", path: "../../packages/kits/SynapseKit"),
        .package(path: "../../packages/libs/SubstrateKernel"),
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
        // MootProductIdentity: canonical path and product-identity constants
        // used by MootInstallerCore, mootx01, MootDaemonProvider,
        // mootx01-daemon-contract-host, and MootCommunityDaemon. EE carries
        // this package; CE carries the same shared targets that import it.
        .package(name: "MootProductIdentity", path: "../../packages/libs/MootProductIdentity"),
        .package(name: "LoopbackHTTP", path: "../../packages/libs/LoopbackHTTP"),
        // CorpusKit: `mootx01 upgrade` reads the persisted provider basis frames
        // (BasisBlobFrame) against the codec version this binary writes
        // (CorpusKitProviders.basisFormatVersion) to converge the dense lanes.
        .package(name: "CorpusKit", path: "../../packages/kits/CorpusKit"),
        // NOTE: ConvergenceKit is NOT listed here. It is an EE-only dependency
        // (the CloudKit/federation sync backend). MootDaemonFederation imports it
        // in Package.swift; that target and this dependency never flow to CE.
    ],
    targets: [
        .target(
            name: "MootEstateOpen",
            dependencies: [
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
            ],
            path: "Sources/MootEstateOpen"
        ),
        .target(
            name: "MootInstallerCore",
            // Each dependency is here for exactly one reason.
            //
            // EstateEncryption: the plaintext→encrypted conversion
            // (CE-1.0.35-08). This module keeps only the app-layer seam — the
            // launchd daemon control — and names the library under the spelling
            // the commands use. Key custody and the open posture live in
            // GeniusLocusKit (EstateOpenPosture), not here.
            //
            // MootDaemonProvider: MACD-3B3 type vocabulary only — ProviderKind
            // and VersionCompatibilityVerdict are the return-type building
            // blocks for ProviderOwnershipProbe. All MAC verification and
            // Keychain access are delegated to the signed bundle subprocess
            // (Kong K2 / MACD-3B3 BRR MUST_UPDATE, Path B). Layering:
            // MootInstallerCore is downstream; MootDaemonProvider is upstream —
            // a legal directed-acyclic edge per CLAUDE.md "downstream→upstream
            // is legal". No layering inversion: MootDaemonProvider depends only
            // on AriaMcpKit; this edge does not close a cycle.
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "EstateEncryption", package: "EstateEncryption"),
                // The installer's tiered permission default reads the
                // mutation-tool inventory from AriaMCP (ToolMutationInventory),
                // the same tables the frozen serve posture refuses. AriaMCP was
                // already reachable transitively through MootDaemonProvider, so
                // this direct edge adds no platform floor.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                "MootDaemonProvider",
            ],
            path: "Sources/MootInstallerCore"
        ),
        // Shared macOS Core AI containment worker. It is linked into the
        // existing mootx01 binary and adds no second installed artifact.
        .target(
            name: "MootCoreAIWorker",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FactExtractionKitProviders", package: "FactExtractionKit"),
            ],
            path: "Sources/MootCoreAIWorker"
        ),
        .target(
            name: "MootFactExtractorActivation",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "FactExtractionKit", package: "FactExtractionKit"),
                .product(name: "FactExtractionKitProviders", package: "FactExtractionKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
            ],
            path: "Sources/MootFactExtractorActivation"
        ),
        .executableTarget(
            name: "mootx01",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                "MootEstateOpen",
                "MootInstallerCore",
                "MootCoreAIWorker",
                "MootFactExtractorActivation",
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
                // CorpusKit + CorpusKitProviders: the dense-pooling convergence
                // step of `mootx01 upgrade` compares persisted basis frames with
                // the current codec format version.
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                // SynapseKit + SubstrateKernel: `mootx01 upgrade` span encode
                // and vector reclaim (see the package comment above).
                .product(name: "SynapseKit", package: "SynapseKit"),
                "SubstrateKernel",
                // VaultKit: DrawerMapping resolver for the kg_facts identity
                // backfill run by `mootx01 upgrade` (MXE-MI).
                .product(name: "VaultKit", package: "VaultKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // ServeCommand's --in-memory path constructs InMemoryStorage
                // directly (accuracy-measurement posture, no filesystem in
                // the measurement path). The module was resolving transitively
                // before this declaration; this makes the dependency explicit
                // rather than accidental.
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // DreamCommand: NeuronKit provides DreamingDaemon + seam adapters;
                // QueueKit provides DrainLease for per-stream stampede prevention.
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Sources/mootx01",
            // GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG: MigrationFloor1_0 above
            // compiles the flat-layout adoption inside EstateCatalog.open; this
            // define compiles FlatLayoutStep and the blocks in
            // InstallCommand/UpgradeCommand that stop the resident before that
            // open and resolve a both-present default slot. Both go when the
            // floor rises above format 1.8.
            swiftSettings: [.define("GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG")]
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
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
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
        .executableTarget(
            name: "mootx01-daemon",
            dependencies: [
                "MootDaemonProvider",
                "MootCommunityDaemon",
            ],
            path: "Sources/mootx01-daemon"
        ),
        .executableTarget(
            name: "mootx01-daemon-contract-host",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
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
        // Community 1.1 daemon composition. This is the shared CE core: estate
        // lifecycle, capture, reviews, Obsidian, transfer, and LAN contracts.
        .target(
            name: "MootCommunityDaemon",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                "MootDaemonProvider",
                "MootEstateOpen",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "SQLCipher", package: "PersistenceKit"),
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "VaultKit", package: "VaultKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                // The estate host runs the migration catalog's prepare step and
                // the manifest refresh after every open, as serve does.
                .product(name: "GeniusLocusKitMigrations", package: "GeniusLocusKit"),
                // CommunityLANCoordinator uses POSIXSocket + HTTPWire for LAN
                // transport. No new package-level dep — LoopbackHTTP is declared
                // above.
                .product(name: "LoopbackHTTP", package: "LoopbackHTTP"),
            ],
            path: "Sources/MootCommunityDaemon"
        ),
        // NOTE: MootDaemonFederation, MootProductDock, and their tests are NOT
        // listed here. They are EE-only targets and must never be declared in
        // this CE manifest. See Package.swift for the full EE target set.
        .testTarget(
            name: "MootFactExtractorActivationTests",
            dependencies: [
                "MootFactExtractorActivation",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "FactExtractionKit", package: "FactExtractionKit"),
                .product(name: "FactExtractionKitProviders", package: "FactExtractionKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
            ],
            path: "Tests/MootFactExtractorActivationTests"
        ),
        .testTarget(
            name: "MootDaemonProviderTests",
            dependencies: ["MootDaemonProvider"],
            path: "Tests/MootDaemonProviderTests"
        ),
        .testTarget(
            name: "MootCommunityDaemonTests",
            dependencies: [
                "MootCommunityDaemon",
                "MootDaemonProvider",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "LocusKitEstateFixture", package: "LocusKit"),
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "GeniusLocusKitMigrations", package: "GeniusLocusKit"),
                .product(name: "VaultKit", package: "VaultKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/MootCommunityDaemonTests",
            exclude: ["PHYSICAL_ACCEPTANCE.md"]
        ),
        .testTarget(
            name: "MootInstallerCoreTests",
            dependencies: [
                "MootEstateOpen",
                "MootInstallerCore",
                // The twenty-row plaintext estate fixture (CE-1.0.35-04). Test
                // support only: detection has to be proven against a REAL estate
                // file, and the production estate is never an acceptable target.
                .product(name: "LocusKitEstateFixture", package: "LocusKit"),
                // AriaMCP: the safety-net test compares the pinned inventory
                // against the live ToolProjection under every opt-in flag
                // combination to catch future drift before it ships as `ask`.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // PersistenceKitSQLite: UpgradeMaintenanceStorageTests opens a
                // fresh maintenance connection over the real SQLite backend.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // SynapseKit: UpgradeMaintenanceStorageTests proves the vector
                // reclaim over a fresh maintenance connection deletes by the
                // declared primary key, which needs VectorStore and its schema
                // declaration. The SynapseKit package is already a dependency
                // of this package; this edge adds no platform floor.
                .product(name: "SynapseKit", package: "SynapseKit"),
            ],
            path: "Tests/MootInstallerCoreTests"
        ),
        .testTarget(
            name: "Mootx01CLITests",
            dependencies: ["mootx01"],
            path: "Tests/Mootx01CLITests"
        ),
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
