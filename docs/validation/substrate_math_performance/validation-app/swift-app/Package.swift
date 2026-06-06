// swift-tools-version:6.0
//
// SubstrateValidator (Swift) — the primary field validator of the substrate libs.
//
// Validates BOTH the shipping lib (packages/libs/*) AND the glref reference
// (via the Harness package), reporting lib-vs-glref drift in addition to
// conformance against the committed vectors. Reuses the Harness Core
// (CanonicalBinaryEncoder, CRC32, HexCoding, VectorFile, KernelSelector,
// Hardware) so the byte mechanism is identical to the harness; the glref-side
// CRC reuses Harness's PrimitiveRegistry.validate directly.
import PackageDescription

let package = Package(
    name: "SubstrateValidator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "substrate-validator", targets: ["SubstrateValidator"]),
    ],
    dependencies: [
        .package(path: "../../test-harness/swift"),
        .package(path: "../../../../../packages/libs/SubstrateTypes"),
        .package(path: "../../../../../packages/libs/SubstrateKernel"),
        .package(path: "../../../../../packages/libs/SubstrateML"),
        .package(path: "../../../../../packages/libs/SubstrateLib"),
    ],
    targets: [
        .executableTarget(
            name: "SubstrateValidator",
            dependencies: [
                // path-dep identity is the directory name ("swift"), not the
                // Package(name:) "GeniusLocusTestHarness".
                .product(name: "Harness", package: "swift"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                .product(name: "SubstrateLib", package: "SubstrateLib"),
            ]
        ),
    ]
)
