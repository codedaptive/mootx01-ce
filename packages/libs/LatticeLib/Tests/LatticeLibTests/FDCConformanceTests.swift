// FDCConformanceTests.swift
//
// Swift half of the shared Swift/Rust deterministic HMM conformance gate.

import Foundation
import Testing
@testable import LatticeLib

private struct ConformanceVector: Codable {
    let input: String
    let code: String?
}

@Suite("FDC Swift/Rust conformance vectors")
struct FDCConformanceTests {
    private func fixtureURL(sourceFile: String = #filePath) -> URL {
        URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rust/tests/fixtures/fdc_conformance.json")
    }

    private func loadVectors() throws -> [ConformanceVector] {
        let url = fixtureURL()
        let data = try #require(
            try? Data(contentsOf: url),
            "fdc_conformance.json must be readable at \(url.path)")
        return try JSONDecoder().decode([ConformanceVector].self, from: data)
    }

    @Test("all HMM conformance vectors match")
    func allConformanceVectorsMatch() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty)
        var failures: [String] = []
        for vector in vectors {
            let got = FDC.encode(vector.input, taggerChoice: .hmm)
            if got != vector.code {
                failures.append(
                    "MISMATCH input=\(vector.input.debugDescription) " +
                    "expected=\(String(describing: vector.code)) got=\(String(describing: got))")
            }
        }
        #expect(
            failures.isEmpty,
            "FDC HMM conformance FAILED:\n\(failures.joined(separator: "\n"))")
    }

    @Test("regenerate conformance fixture (REGEN_FDC_FIXTURE=1 only)")
    func regenerateConformanceFixture() throws {
        guard ProcessInfo.processInfo.environment["REGEN_FDC_FIXTURE"] == "1" else {
            return
        }
        let updated = try loadVectors().map {
            ConformanceVector(input: $0.input, code: FDC.encode($0.input, taggerChoice: .hmm))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: fixtureURL(), options: .atomic)
        let general = updated.filter { $0.code == "000" }.count
        print("Regenerated \(fixtureURL().path): \(updated.count) vectors, \(general) general")
    }
}
