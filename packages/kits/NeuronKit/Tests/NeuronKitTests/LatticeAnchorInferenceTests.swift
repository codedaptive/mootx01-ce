// LatticeAnchorInferenceTests.swift
//
// Peer to `Sources/NeuronKit/LatticeAnchorInference.swift`: the
// `LatticeAnchorInference` value type, its provenance-aligned raw
// values, and the `NeuronKit.inferLatticeAnchor` entry point.

import Foundation
import Testing
@testable import NeuronKit

@Suite("LatticeAnchorInference")
struct LatticeAnchorInferenceTests {

    @Test("inference round-trips through Codable")
    func inferenceRoundTrip() throws {
        let inference = LatticeAnchorInference(
            code: "004.42",
            wikidataQID: "Q21198",
            confidence: AnchorConfidence.medium.rawValue,
            enrichmentStatusBits: EnrichmentStatus.qidCompleted.rawValue,
            pipelineMode: .deterministicReference
        )

        let data = try JSONEncoder().encode(inference)
        let decoded = try JSONDecoder().decode(LatticeAnchorInference.self, from: data)

        #expect(decoded == inference)
    }

    @Test("confidence levels match provenance field values")
    func confidenceLevelsMatchProvenanceFieldValues() {
        #expect(AnchorConfidence.null.rawValue == 0)
        #expect(AnchorConfidence.low.rawValue == 16)
        #expect(AnchorConfidence.medium.rawValue == 32)
        #expect(AnchorConfidence.high.rawValue == 48)
        #expect(AnchorConfidence.verified.rawValue == 56)
    }

    @Test("enrichment status values match cookbook § 2.5")
    func enrichmentStatusValuesMatchCookbookSection2_5() {
        #expect(EnrichmentStatus.none.rawValue == 0)
        #expect(EnrichmentStatus.qidPending.rawValue == 1)
        #expect(EnrichmentStatus.qidCompleted.rawValue == 2)
        #expect(EnrichmentStatus.closureCached.rawValue == 3)
    }
}

@Suite("inferLatticeAnchor")
struct InferLatticeAnchorTests {

    @Test("nonsense term produces qidPending via the 000 sentinel")
    func nonsenseTermProducesQidPendingViaThe000Sentinel() {
        // An UNRESOLVED term (pure gibberish — no real tokens, so the
        // concept bag is empty) no longer yields an empty FDC code. The
        // v3/v4 FDC classifier's hierarchy mode falls back to the "000"
        // Generalities/unclassified sentinel for any nonempty text that
        // fails to resolve a specific code — empty code is reserved for
        // genuinely empty/whitespace-only input. A "000" code never
        // carries a Q-ID, so `inferLatticeAnchor`'s status derivation
        // (branches on `code.isEmpty` before `wikidataQID == nil`) takes
        // the non-empty-code branch and reports `.qidPending`, not
        // `.none`. The term must contain no real words: any dictionary
        // word (e.g. "nonsense") would resolve.
        let inference = NeuronKit.inferLatticeAnchor("zxcvqwertyasdfgh qwertyzxcvb")
        #expect(inference.code == "000")
        #expect(inference.wikidataQID == nil)
        #expect(inference.enrichmentStatusBits == EnrichmentStatus.qidPending.rawValue)
    }

    @Test("realistic multi-token content produces qidCompleted status")
    func realisticContentProducesQidCompletedStatus() {
        // Production NEVER feeds the encoder a bare single noun — the FDC
        // anchor is computed over real captured content (drawer.content /
        // frame.content), which is always multi-token. A single token (e.g.
        // "chemistry") maps to one very common Q-ID present in ~111 code
        // signatures, so every candidate ties at the same Raw score and the
        // tie-count guard (maximumTiedWinnersForClassification) correctly
        // returns UNRESOLVED — a confidently-wrong specific code is worse than
        // the honest "000" sentinel. Multi-token content carries several Q-IDs
        // whose overlap DISCRIMINATES one code, so a winner emerges and the
        // anchor resolves with a Q-ID → status = qidCompleted. This input
        // resolves to FDC code "547" (organic chemistry) on both ports.
        let inference = NeuronKit.inferLatticeAnchor(
            "organic chemistry of carbon compounds and reactions")
        #expect(!inference.code.isEmpty)
        #expect(inference.wikidataQID != nil)
        #expect(inference.enrichmentStatusBits == EnrichmentStatus.qidCompleted.rawValue)
    }

    @Test("inference carries the current pipeline mode")
    func inferenceCarriesCurrentPipelineMode() {
        let inference = NeuronKit.inferLatticeAnchor("any term")
        #expect(inference.pipelineMode == NeuronKit.linguisticPipelineMode)
    }
}
