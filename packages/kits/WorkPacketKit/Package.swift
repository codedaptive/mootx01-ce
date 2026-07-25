// swift-tools-version: 6.2
//
// WorkPacketKit — durable agentic work-packet schema and drawer-backed store.
//
// A Work Packet is a typed projection over standard LocusKit drawers
// (kind `.structuredJSON`, room `"work-packets"`) plus typed tunnels for
// lineage edges (`derivesFrom` / `respondsTo`). Zero new persistence
// machinery: sync, federation, export, and search compatibility come
// for free from the existing estate substrate.
//
// Swift-only; no Rust twin required — packet content persists as estate
// memories via existing drawer + tunnel primitives per FAB5-I1.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "WorkPacketKit".

import PackageDescription

let package = Package(
    name: "WorkPacketKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "WorkPacketKit",
            targets: ["WorkPacketKit"]
        ),
    ],
    dependencies: [
        // LocusKit supplies Estate, Drawer, Tunnel, CaptureFrame,
        // TunnelCaptureFrame, RecallFrame, RecallStream, Filter, LatticeAnchor,
        // ContentKind, TunnelKind — the complete substrate write/read surface.
        // WorkPacketKit calls no SQL directly; all persistence routes through
        // the WorkPacketEstateClient protocol (satisfied by EstateAdapter in
        // production, a mock in tests).
        .package(path: "../LocusKit"),
    ],
    targets: [
        .target(
            name: "WorkPacketKit",
            dependencies: [
                .product(name: "LocusKit", package: "LocusKit"),
            ]
        ),
        .testTarget(
            name: "WorkPacketKitTests",
            dependencies: [
                "WorkPacketKit",
                .product(name: "LocusKit", package: "LocusKit"),
            ]
        ),
    ]
)
