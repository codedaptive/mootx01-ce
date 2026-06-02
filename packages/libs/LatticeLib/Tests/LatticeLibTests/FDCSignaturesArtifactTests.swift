// FDCSignaturesArtifactTests.swift
//
// The bundled FDCSignatures.json artifact contract
// (FDC_ENCODER_CANONICAL § 2/§ 7-build, cookbook § 7): the runtime
// artifact is MEMBERSHIP-ONLY — per-term weights are dropped at
// compaction and the matcher never sees a source weight; the
// source_weights field is build provenance, not runtime input. These
// tests pin the artifact shape the spec documents, so a regenerated
// artifact that silently changes shape (weights reappearing, codes
// dropped, unsorted terms) fails here before it ships.

import Foundation
import Testing
@testable import LatticeLib

@Suite("FDCSignatures artifact contract")
struct FDCSignaturesArtifactTests {

    /// The compact artifact's wire shape (mirrors the runtime loader's).
    private struct Artifact: Decodable {
        struct Entry: Decodable {
            let code: String
            let terms: [String]
        }
        let version: String
        let source_weights: [String: Int]
        let codes: [Entry]
    }

    private func loadArtifact() throws -> Artifact {
        let url = try #require(
            Bundle.module.url(forResource: "FDCSignatures", withExtension: "json"))
        return try JSONDecoder().decode(Artifact.self, from: Data(contentsOf: url))
    }

    @Test("artifact is membership-only with provenance header")
    func artifactShapeAndProvenance() throws {
        let artifact = try loadArtifact()
        #expect(!artifact.version.isEmpty)
        // Build provenance: the pinned source weights ride along even
        // though the runtime never reads them.
        #expect(artifact.source_weights == ["label": 3, "title": 2, "article": 1])
    }

    @Test("all 1071 signature-bearing codes ship, sorted, non-empty")
    func fullCodeCoverageSortedNonEmpty() throws {
        let artifact = try loadArtifact()
        #expect(artifact.codes.count == 1071)
        let codes = artifact.codes.map(\.code)
        #expect(codes == codes.sorted(), "codes are in sorted order")
        #expect(Set(codes).count == codes.count, "no duplicate codes")
        for entry in artifact.codes {
            #expect(!entry.terms.isEmpty, "code \(entry.code) has a non-empty signature")
        }
    }

    @Test("every code's term list is sorted (deterministic artifact)")
    func termListsSorted() throws {
        let artifact = try loadArtifact()
        for entry in artifact.codes {
            #expect(entry.terms == entry.terms.sorted(),
                    "code \(entry.code) terms are sorted")
        }
    }
}
