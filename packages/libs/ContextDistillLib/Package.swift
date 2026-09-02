// swift-tools-version: 6.2
//
// ContextDistillLib — deterministic distillation candidates for Model-Plus experiments.
//
// Ports distill_plus_converter.py and record_shape_classifier.py to Swift and Rust
// so the same selection logic runs both on-device (Swift, Apple platforms) and
// on PC/Linux (Rust). Neither port uses regex; all patterns are hand-written
// scanners that mirror the Python reference byte-for-byte.
//
// Depends on nothing. Sits alongside AriaLexiconLib as a pure-vocabulary library.

import PackageDescription

let package = Package(
    name: "ContextDistillLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "ContextDistillLib",
            targets: ["ContextDistillLib"]
        ),
    ],
    targets: [
        .target(
            name: "ContextDistillLib"
        ),
        .testTarget(
            name: "ContextDistillLibTests",
            dependencies: ["ContextDistillLib"],
            // Vectors/ is copied into the test bundle so OracleVectors.swift can
            // load them via Bundle.module regardless of build system or test runner.
            resources: [
                .copy("Vectors"),
            ]
        ),
    ]
)
