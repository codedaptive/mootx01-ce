// LookupConformanceTests.swift
//
// Cross-language conformance gate for EideticLib.lookup.
//
// Reads Tests/SharedVectors/lookup_vectors.json (schema_version 2) and
// asserts that Swift EideticLib.lookup produces the expected FDC code and
// Wikidata Q-ID for every vector. The Rust half lives in
// rust/src/lib.rs (unit tests) and exercises the same contract.
//
// These vectors pin the exact output of EideticLib.lookup for both engines.
// A divergence between Swift and Rust is a parity violation.
//
// schema_version history:
//   v1 (PAR-3B-EL): used `expected_udc` populated with UDC codes — wrong
//      classification system; no test consumed that version.
//   v2 (w3-latticelib-fdc): renamed to `expected_code`, populated with real
//      FDC codes verified against both Swift and Rust engines.

import Testing
import Foundation
@testable import EideticLib
import LatticeLib

// MARK: - Vector schema

private struct LookupVectorFile: Decodable {
    let schemaVersion: String
    let vectors: [LookupVector]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case vectors
    }
}

private struct LookupVector: Decodable {
    let id: String
    let input: String
    /// Expected FDC code. Empty string means UNRESOLVED.
    let expectedCode: String
    /// Expected dominant concept Wikidata Q-ID, or nil.
    let expectedQID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case input
        case expectedCode = "expected_code"
        case expectedQID = "expected_qid"
    }
}

// MARK: - Conformance suite

@Suite("EideticLib lookup conformance vectors")
struct LookupConformanceTests {

    private func loadVectors() throws -> LookupVectorFile {
        let url = try #require(
            Bundle.module.url(
                forResource: "lookup_vectors",
                withExtension: "json",
                subdirectory: "SharedVectors"
            ),
            "lookup_vectors.json must ship in the test bundle under SharedVectors/"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LookupVectorFile.self, from: data)
    }

    @Test("lookup_vectors schema version is 2")
    func schemaVersion() throws {
        let file = try loadVectors()
        // Schema version 2 carries FDC codes in expected_code (v1 had the
        // wrong expected_udc field with UDC codes — a different system).
        #expect(file.schemaVersion == "2")
        #expect(!file.vectors.isEmpty)
    }

    /// Every vector produces the expected FDC code from EideticLib.lookup.
    /// An empty `expected_code` means UNRESOLVED — lookup must return
    /// an empty anchor code, never a guess.
    @Test("all lookup vectors match expected FDC code")
    func allVectorsMatchCode() throws {
        let file = try loadVectors()
        #expect(FDC.isAvailable, "LatticeLib FDC runtime must be available")

        var failures: [String] = []
        for v in file.vectors {
            let anchor = EideticLib.lookup(v.input)
            if anchor.code != v.expectedCode {
                failures.append(
                    "\(v.id): input=\(v.input.debugDescription) expected_code=\(v.expectedCode.debugDescription) got=\(anchor.code.debugDescription)"
                )
            }
        }

        let report = failures.joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "Lookup conformance FAILED: \(failures.count)/\(file.vectors.count) vectors diverge:\n\(report)"
        )
    }

    /// Regenerate lookup_vectors.json with the current EideticLib.lookup output.
    /// Only runs when REGEN_LOOKUP_VECTORS=1 is set in the environment.
    ///
    /// Usage: REGEN_LOOKUP_VECTORS=1 swift test --filter regenerateLookupVectors
    ///
    /// After running, commit the updated fixture. The expected_code values for
    /// single-word inputs that previously returned specific codes may now be ""
    /// (UNRESOLVED) because the honest-classification guard (tie-count) correctly
    /// identifies these as degenerate bags.
    @Test("regenerate lookup vectors (REGEN_LOOKUP_VECTORS=1 only)")
    func regenerateLookupVectors() throws {
        guard ProcessInfo.processInfo.environment["REGEN_LOOKUP_VECTORS"] == "1" else {
            return  // skip silently — operator-triggered action only
        }

        let file = try loadVectors()
        guard let bundleURL = Bundle.module.url(forResource: "lookup_vectors", withExtension: "json", subdirectory: "SharedVectors") else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot locate lookup_vectors.json in bundle"])
        }

        // Walk up from bundle URL to find the source file at Tests/SharedVectors/lookup_vectors.json
        // The bundle path is deep inside .build/; we use #filePath to locate the source.
        let sourceFile = #filePath
        let thisFile = URL(fileURLWithPath: sourceFile)
        let testsDir = thisFile
            .deletingLastPathComponent()  // EideticLibTests/
            .deletingLastPathComponent()  // Tests/
        let sharedVectorsURL = testsDir
            .appendingPathComponent("SharedVectors")
            .appendingPathComponent("lookup_vectors.json")

        struct OutputVector: Encodable {
            let id: String
            let input: String
            let expected_code: String
            let expected_qid: String?
        }
        struct OutputFile: Encodable {
            let schema_version: String
            let vectors: [OutputVector]
        }

        let updated = file.vectors.map { v -> OutputVector in
            let anchor = EideticLib.lookup(v.input)
            return OutputVector(
                id: v.id,
                input: v.input,
                expected_code: anchor.code,
                expected_qid: anchor.wikidataQID
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let outputFile = OutputFile(schema_version: file.schemaVersion, vectors: updated)
        let data = try encoder.encode(outputFile)
        try data.write(to: sharedVectorsURL, options: .atomic)

        let nilCount = updated.filter { $0.expected_code.isEmpty }.count
        print("Regenerated \(sharedVectorsURL.path)")
        print("  total vectors: \(updated.count)")
        print("  UNRESOLVED (empty code): \(nilCount)")
        print("  resolved: \(updated.count - nilCount)")
    }

    /// Every vector with a non-null expected_qid must produce the matching
    /// Q-ID from EideticLib.lookup. Vectors with null expected_qid must
    /// produce nil.
    @Test("all lookup vectors match expected Wikidata Q-ID")
    func allVectorsMatchQID() throws {
        let file = try loadVectors()
        #expect(FDC.isAvailable, "LatticeLib FDC runtime must be available")

        var failures: [String] = []
        for v in file.vectors {
            let anchor = EideticLib.lookup(v.input)
            if anchor.wikidataQID != v.expectedQID {
                failures.append(
                    "\(v.id): input=\(v.input.debugDescription) expected_qid=\(v.expectedQID.map { "\"\($0)\"" } ?? "nil") got=\(anchor.wikidataQID.map { "\"\($0)\"" } ?? "nil")"
                )
            }
        }

        let report = failures.joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "Lookup Q-ID conformance FAILED: \(failures.count)/\(file.vectors.count) vectors diverge:\n\(report)"
        )
    }
}
