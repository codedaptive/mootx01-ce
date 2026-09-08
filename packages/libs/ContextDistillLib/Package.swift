// swift-tools-version: 6.2
//
// ContextDistillLib — deterministic distillation candidates for Model-Plus experiments.
//
// Ports distill_plus_converter.py and record_shape_classifier.py to Swift and Rust
// so the same logic runs both on-device (Swift, Apple platforms) and on
// PC/Linux (Rust). Complete-form reducers and passage views are deterministic;
// Foundation regex and local scanners implement the narrow supported grammars.
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
            // Oracle/ holds the frozen Python reference implementation and the
            // vector generators; they are documentation and tooling, not test
            // sources or resources, so SwiftPM must be told to leave them alone.
            exclude: ["Oracle"],
            resources: [
                .copy("Vectors"),
            ]
        ),
    ]
)
