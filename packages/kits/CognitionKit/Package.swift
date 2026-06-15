// swift-tools-version: 6.2
//
// CognitionKit, the behaviour-recipe layer of the MOOTx01 substrate —
// the "conscious mind." CognitionKit assembles shipped NeuronKit
// reasoning functions and GeniusLocusKit estate verbs into named,
// reusable workflows ("recipes"). It implements no algorithms of its
// own and holds no substrate state (spec B-1 / B-2): every read and
// write passes through NeuronKit or the passed GeniusLocusKit estate
// handle. A recipe is a sequence of calls, not an implementation.
//
// Dependencies are downward-only per the kit topology:
//   - GeniusLocusKit: the EstateHandle and the nine estate verbs +
//     COW branch verbs (the substrate boundary; all writes descend here).
//   - NeuronKit: the reasoning surface CognitionKit sequences
//     (hybridRecall, ContextSynthesizer, benchmark, runTournament,
//     branch ops). NeuronKit's public functions are free functions /
//     static members on the `NeuronKit` namespace — there is no
//     "NeuronKitHandle" type; recipes call them directly.
//   - LocusKit: the read-only Drawer / RecallFrame / Filter value types
//     recipes name in their inputs and outputs (no LocusKit verb call,
//     no SQL — same read-only value-type posture NeuronKit takes).
//   - SubstrateTypes: HLC and shared value types.
//
// Per DESIGN_CONSTRAINTS.md C-1 this kit takes NO external runtime
// dependencies — pure Swift over the in-tree kits above.

import PackageDescription

let package = Package(
    name: "CognitionKit",
    platforms: [
        // Aligned with GeniusLocusKit / NeuronKit (macOS 15 / iOS 18)
        // so the estate-handle and reasoning dependencies resolve cleanly.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "CognitionKit",
            targets: ["CognitionKit"]
        ),
    ],
    dependencies: [
        .package(path: "../GeniusLocusKit"),
        .package(path: "../NeuronKit"),
        .package(path: "../LocusKit"),
        .package(path: "../../libs/SubstrateTypes"),
        // IntellectusLib is the zero-dependency telemetry leaf.
        // CognitionKit emits self-report metrics at recipe-run boundaries
        // (cp-cognitionkit-report P2 self-report coverage;
        // DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28). When monitoring is
        // off (the default), every Intellectus.report(...) call is a single
        // atomic load + branch — zero allocation, no clock. IntellectusLib
        // depends on nothing; layering is safe (it is the new dependency
        // floor below SubstrateKernel). Mirrors the NeuronKit pattern.
        .package(path: "../../libs/IntellectusLib"),
        // SubstrateML provides the ARM engine (mineAssociationRules,
        // MiningThresholds, AssociationRule, Item) consumed by AssociationRules.swift.
        .package(path: "../../libs/SubstrateML"),
        // PersistenceKit's in-memory and SQLite backends are test-only
        // dependencies: the recipe tests open real GeniusLocusKit estates
        // exercising the full substrate boundary rather than mocks.
        // SQLite is required for the Contradiction SQLite-backed test
        // (CK-CN-4) that proves content hydration is not silently
        // masked by InMemory (InMemory returns content regardless of
        // hydrationLevel; SQLite enforces spec § 7.3 strictly).
        // Declared at the package level; wired only into the test target.
        .package(path: "../PersistenceKit"),
    ],
    targets: [
        .target(
            name: "CognitionKit",
            dependencies: [
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                // Telemetry leaf — see dependency note above.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                .product(name: "SubstrateML", package: "SubstrateML"),
            ],
            path: "Sources/CognitionKit"
        ),
        .testTarget(
            name: "CognitionKitTests",
            dependencies: [
                "CognitionKit",
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                // SubstrateML provides ARM types (MiningThresholds) used
                // in AssociationRulesTests.
                .product(name: "SubstrateML", package: "SubstrateML"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // SQLite backend: used by CK-CN-4 to prove that the
                // .full hydration override in Contradiction is exercised
                // against the real blob-gated storage path. InMemory
                // masks the bug; SQLite enforces it.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Tests/CognitionKitTests",
            // Shared conformance vectors — one artifact read by the Swift
            // CognitionVectorConformanceTests suite AND by
            // rust/tests/cognition_conformance.rs (BYCOPY_MIGRATION_001).
            resources: [.copy("Fixtures")]
        ),
    ]
)
