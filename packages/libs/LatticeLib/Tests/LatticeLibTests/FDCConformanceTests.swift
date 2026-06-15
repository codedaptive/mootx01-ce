// FDCConformanceTests.swift
//
// Swift half of the FDC Swift↔Rust cross-language conformance gate.
//
// Reads the shared fixture at rust/tests/fixtures/fdc_conformance.json
// using a compile-time path anchor so no resource bundling is required.
// The Rust half lives in rust/tests/fdc_conformance_test.rs and reads
// the same file via include_bytes!.
//
// Conformance structure:
//
//   * Most vectors — table-resident tokens or tokens where NLTagger and HMM
//     agree — run on ALL platforms. Both Swift (Apple + non-Apple) and Rust
//     must produce the same code.
//
//   * 3 "platform-divergent" vectors (marked with platform_note in the
//     fixture) contain only novel tokens where Apple's NLTagger and the
//     integer-Viterbi HMM classify them differently. The codes in the fixture
//     are the Rust-HMM baseline. On Apple, Swift uses NLTagger for novel
//     tokens and produces different codes — that is expected and correct
//     behaviour, not a parity violation. The cross-port HMM identity contract
//     (Swift-non-Apple-HMM == Rust-HMM) is gated separately in
//     LatticeLanguageConformanceTests (tag_conformance.json). Those 3 vectors
//     are skipped on Apple in this test.
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
    /// Non-nil for the 3 vectors where Apple NLTagger and the HMM produce
    /// different codes. The Rust-HMM baseline is in `code`; Apple Swift
    /// uses NLTagger for novel tokens and legitimately diverges. These
    /// vectors are skipped on Apple in the Swift conformance test.
    let platformNote: String?
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

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try #require(
            try? Data(contentsOf: fixtureURL),
            "fdc_conformance.json must be readable at \(fixtureURL.path)"
        )
        return try decoder.decode([ConformanceVector].self, from: data)
    }

    /// Every vector in the shared fixture must produce the expected code
    /// (or nil for UNRESOLVED) from Swift FDC.encode. Vectors marked with
    /// `platform_note` are platform-divergent (Apple NLTagger vs HMM); those
    /// are skipped on Apple where NLTagger is the novel-token engine. On
    /// non-Apple platforms all vectors run. The Rust half gates the same
    /// fixture file via fdc_conformance_test.rs.
    @Test("all conformance vectors match")
    func allConformanceVectorsMatch() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty, "fixture must contain at least one vector")
        #expect(FDC.isAvailable, "bundled FDC artifacts must load")

#if canImport(NaturalLanguage)
        // On Apple, skip the 3 vectors where NLTagger and HMM diverge.
        // NLTagger is the correct engine on Apple — the divergence is expected.
        // The cross-port HMM identity gate (Swift-non-Apple == Rust) is in
        // LatticeLanguageConformanceTests (tag_conformance.json).
        let runnable = vectors.filter { $0.platformNote == nil }
        let skipped = vectors.count - runnable.count
        if skipped > 0 {
            print("FDC conformance: skipping \(skipped) Apple-NLTagger-divergent vector(s) (expected)")
        }
#else
        // Non-Apple: HMM is the novel-token engine, same as Rust. All vectors run.
        let runnable = vectors
#endif

        var failures: [String] = []
        for v in runnable {
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
            "FDC conformance FAILED: \(failures.count)/\(runnable.count) vectors diverge:\n\(report)"
        )
    }
}
