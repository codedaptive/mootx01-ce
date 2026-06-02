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

    @Test("nonsense term produces enrichmentStatus none")
    func nonsenseTermProducesEnrichmentStatusNone() {
        // An UNRESOLVED term (pure gibberish — no real tokens, so the
        // concept bag is empty) yields an empty FDC code, which means
        // enrichment_status = none (the substrate has not yet produced
        // an anchor for this content). The term must contain no real
        // words: any dictionary word (e.g. "nonsense") would resolve.
        let inference = NeuronKit.inferLatticeAnchor("zxcvqwertyasdfgh qwertyzxcvb")
        #expect(inference.code == "")
        #expect(inference.wikidataQID == nil)
        #expect(inference.enrichmentStatusBits == EnrichmentStatus.none.rawValue)
    }

    @Test("chemistry term produces qidCompleted status")
    func chemistryTermProducesQidCompletedStatus() {
        // EideticLib resolves chemistry to an FDC code, and the input's
        // dominant concept supplies the Q-ID; code and Q-ID both
        // populated means status = qidCompleted.
        let inference = NeuronKit.inferLatticeAnchor("chemistry")
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
