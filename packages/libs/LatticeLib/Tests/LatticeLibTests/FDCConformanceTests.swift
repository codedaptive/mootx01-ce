// FDCConformanceTests.swift
//
// Swift half of the FDC Swift↔Rust cross-language conformance gate.
//
// Reads the shared fixture at rust/tests/fixtures/fdc_conformance.json
// using a compile-time path anchor so no resource bundling is required.
// The Rust half lives in rust/tests/fdc_conformance_test.rs and reads
// the same file via include_bytes!.
//
// Both legs must pass 100% against the same fixture file before merge.
// Any divergence between legs is a parity violation — the FDC encoder
// agreement property requires bit-identical output across platforms.
//
// Seed: N/A (determinism comes from the pinned artifacts and algorithm,
// not from a hash-family seed).

import Testing
import Foundation
@testable import LatticeLib

// MARK: - Vector schema (mirrors the Rust ConformanceVector struct)

private struct ConformanceVector: Decodable {
    /// The input text.
    let input: String
    /// The expected FDC code, or nil for UNRESOLVED (no-code cases omit
    /// the `code` key in the JSON — the schema uses presence/absence,
    /// not explicit null).
    let code: String?
}

// MARK: - Conformance test

@Suite("FDC Swift/Rust conformance vectors")
struct FDCConformanceTests {

    /// Loads the shared conformance fixture using a compile-time path anchor.
    ///
    /// `#filePath` resolves to this source file's absolute path at compile
    /// time. The fixture lives at rust/tests/fixtures/fdc_conformance.json
    /// relative to the LatticeLib package root. We walk up four directories
    /// from this test file (Tests/LatticeLibTests/ → Tests/ → package root)
    /// then down to rust/tests/fixtures/.
    ///
    /// This avoids resource bundling (which would create a separate test
    /// bundle and break the existing FDCSignaturesArtifactTests that rely on
    /// Bundle.module resolving to the main LatticeLib target's bundle).
    private func loadVectors(sourceFile: String = #filePath) throws -> [ConformanceVector] {
        // __file is in Tests/LatticeLibTests/FDCConformanceTests.swift.
        // Walk: ← FDCConformanceTests.swift (filename)
        //       ← LatticeLibTests/      (1 up)
        //       ← Tests/               (2 up)
        //       → rust/tests/fixtures/fdc_conformance.json (package root + path)
        let thisFile = URL(fileURLWithPath: sourceFile)
        let packageRoot = thisFile
            .deletingLastPathComponent()  // LatticeLibTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root (LatticeLib/)
        let fixtureURL = packageRoot
            .appendingPathComponent("rust")
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("fdc_conformance.json")

        let data = try #require(
            try? Data(contentsOf: fixtureURL),
            "fdc_conformance.json must be readable at \(fixtureURL.path)"
        )
        return try JSONDecoder().decode([ConformanceVector].self, from: data)
    }

    /// Every vector in the shared fixture must produce the expected code
    /// (or nil for UNRESOLVED) from Swift FDC.encode. This is the Swift
    /// half of the cross-language agreement property: the Rust engine
    /// must pass the same vectors via fdc_conformance_test.rs.
    @Test("all conformance vectors match")
    func allConformanceVectorsMatch() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty, "fixture must contain at least one vector")
        #expect(FDC.isAvailable, "bundled FDC artifacts must load")

        var failures: [String] = []
        for v in vectors {
            let got = FDC.encode(v.input)
            if got != v.code {
                failures.append(
                    "MISMATCH input=\(v.input.debugDescription) expected=\(v.code.map { "\"\($0)\"" } ?? "nil") got=\(got.map { "\"\($0)\"" } ?? "nil")"
                )
            }
        }

        let report = failures.joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "FDC conformance FAILED: \(failures.count)/\(vectors.count) vectors diverge:\n\(report)"
        )
    }
}
