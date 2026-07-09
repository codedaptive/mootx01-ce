// FDCSignaturesArtifactTests.swift
//
// The bundled FDCSignatures.json artifact contract
// (FDC_ENCODER_CANONICAL § 2/§ 7-build, cookbook § 7): the runtime
// artifact keeps source-owned term lists separate from inherited terms.
// This is the v3 precision contract: article and ancestor recall cannot
// masquerade as heading/alias evidence.

import Foundation
import Testing
@testable import LatticeLib

@Suite("FDCSignatures artifact contract")
struct FDCSignaturesArtifactTests {

    /// The compact artifact's wire shape (mirrors the runtime loader's).
    private struct Artifact: Decodable {
        struct Entry: Decodable {
            let code: String
            let label_terms: [String]
            let alias_terms: [String]
            let title_terms: [String]
            let article_terms: [String]
            let ancestor_terms: [String]
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

    @Test("artifact carries source ownership with provenance header")
    func artifactShapeAndProvenance() throws {
        let artifact = try loadArtifact()
        #expect(!artifact.version.isEmpty)
        // Build provenance: the pinned source weights ride along even
        // though the runtime never reads them.
        #expect(artifact.source_weights == ["label": 3, "alias": 4, "title": 2, "article": 1])
    }

    @Test("all 1075 unique frame codes ship, sorted, non-empty")
    func fullCodeCoverageSortedNonEmpty() throws {
        let artifact = try loadArtifact()
        #expect(artifact.codes.count == 1075)
        let codes = artifact.codes.map(\.code)
        #expect(codes == codes.sorted(), "codes are in sorted order")
        #expect(Set(codes).count == codes.count, "no duplicate codes")
        for entry in artifact.codes {
            let own = entry.label_terms + entry.alias_terms + entry.title_terms + entry.article_terms
            #expect(!own.isEmpty, "code \(entry.code) has non-empty owned evidence")
        }
    }

    @Test("every code's term list is sorted (deterministic artifact)")
    func termListsSorted() throws {
        let artifact = try loadArtifact()
        for entry in artifact.codes {
            for terms in [entry.label_terms, entry.alias_terms, entry.title_terms,
                          entry.article_terms, entry.ancestor_terms] {
                #expect(terms == terms.sorted(), "code \(entry.code) terms are sorted")
                #expect(Set(terms).count == terms.count, "code \(entry.code) terms are unique")
            }
        }
    }
}
