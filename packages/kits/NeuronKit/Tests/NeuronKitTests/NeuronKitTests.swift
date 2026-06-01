// NeuronKitTests.swift
//
// Initial test surface. As reasoning and autonomic functions land,
// each gets its own test file. This file holds the module-level
// smoke tests.

import Testing
import Foundation
@testable import NeuronKit

@Suite("NeuronKit module smoke tests")
struct NeuronKitTests {

    @Test("module version is pinned")
    func moduleVersion() {
        #expect(NeuronKit.version == "0.1.0")
    }

    @Test("linguistic pipeline mode tracks the build configuration")
    func linguisticPipelineModeBuildConfiguration() {
        let mode = NeuronKit.linguisticPipelineMode
        #if APPLE_NLP_ACCEL
        #expect(mode == .appleNLAccel)
        #expect(mode.rawValue == "apple-nl-accel")
        #else
        #expect(mode == .deterministicReference)
        #expect(mode.rawValue == "deterministic-reference")
        #endif
    }
}

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

    @Test("enrichment status values match cookbook §2.5")
    func enrichmentStatusValuesMatchCookbookSection2_5() {
        #expect(EnrichmentStatus.none.rawValue == 0)
        #expect(EnrichmentStatus.qidPending.rawValue == 1)
        #expect(EnrichmentStatus.qidCompleted.rawValue == 2)
        #expect(EnrichmentStatus.closureCached.rawValue == 3)
    }
}

@Suite("inferLatticeAnchor")
struct InferLatticeAnchorTests {

    @Test("a nonsense term produces enrichment status none")
    func nonsenseTermProducesEnrichmentStatusNone() {
        // No canon match means empty MDCC code, which means
        // enrichment_status = none (the substrate has not yet
        // produced an anchor for this content).
        let inference = NeuronKit.inferLatticeAnchor("qwertyzxcvb nonsense")
        #expect(inference.code == "")
        #expect(inference.wikidataQID == nil)
        #expect(inference.enrichmentStatusBits == EnrichmentStatus.none.rawValue)
    }

    @Test("a chemistry term produces qidCompleted status")
    func chemistryTermProducesQidCompletedStatus() {
        // EideticLib resolves chemistry to an MDCC canon entry whose
        // sourceIdentity is its Q-ID; MDCC code and Q-ID both
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
