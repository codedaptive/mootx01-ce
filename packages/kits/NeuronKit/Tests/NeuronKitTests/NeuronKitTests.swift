// NeuronKitTests.swift
//
// Initial test surface. As reasoning and autonomic functions land,
// each gets its own test file. This file holds the module-level
// smoke tests.

import XCTest
@testable import NeuronKit

final class NeuronKitTests: XCTestCase {

    func testModuleVersion() {
        XCTAssertEqual(NeuronKit.version, "0.1.0")
    }

    func testLinguisticPipelineModeBuildConfiguration() {
        let mode = NeuronKit.linguisticPipelineMode
        #if APPLE_NLP_ACCEL
        XCTAssertEqual(mode, .appleNLAccel)
        XCTAssertEqual(mode.rawValue, "apple-nl-accel")
        #else
        XCTAssertEqual(mode, .deterministicReference)
        XCTAssertEqual(mode.rawValue, "deterministic-reference")
        #endif
    }
}

final class LatticeAnchorInferenceTests: XCTestCase {

    func testInferenceRoundTrip() throws {
        let inference = LatticeAnchorInference(
            code: "004.42",
            wikidataQID: "Q21198",
            confidence: AnchorConfidence.medium.rawValue,
            enrichmentStatusBits: EnrichmentStatus.qidCompleted.rawValue,
            pipelineMode: .deterministicReference
        )

        let data = try JSONEncoder().encode(inference)
        let decoded = try JSONDecoder().decode(LatticeAnchorInference.self, from: data)

        XCTAssertEqual(decoded, inference)
    }

    func testConfidenceLevelsMatchProvenanceFieldValues() {
        XCTAssertEqual(AnchorConfidence.null.rawValue, 0)
        XCTAssertEqual(AnchorConfidence.low.rawValue, 16)
        XCTAssertEqual(AnchorConfidence.medium.rawValue, 32)
        XCTAssertEqual(AnchorConfidence.high.rawValue, 48)
        XCTAssertEqual(AnchorConfidence.verified.rawValue, 56)
    }

    func testEnrichmentStatusValuesMatchCookbookSection2_5() {
        XCTAssertEqual(EnrichmentStatus.none.rawValue, 0)
        XCTAssertEqual(EnrichmentStatus.qidPending.rawValue, 1)
        XCTAssertEqual(EnrichmentStatus.qidCompleted.rawValue, 2)
        XCTAssertEqual(EnrichmentStatus.closureCached.rawValue, 3)
    }
}

final class InferLatticeAnchorTests: XCTestCase {

    func testNonsenseTermProducesEnrichmentStatusNone() {
        // No canon match means empty MDCC code, which means
        // enrichment_status = none (the substrate has not yet
        // produced an anchor for this content).
        let inference = NeuronKit.inferLatticeAnchor("qwertyzxcvb nonsense")
        XCTAssertEqual(inference.code, "")
        XCTAssertNil(inference.wikidataQID)
        XCTAssertEqual(
            inference.enrichmentStatusBits,
            EnrichmentStatus.none.rawValue
        )
    }

    func testChemistryTermProducesQidCompletedStatus() {
        // EideticLib resolves chemistry to an MDCC canon entry whose
        // sourceIdentity is its Q-ID; MDCC code and Q-ID both
        // populated means status = qidCompleted.
        let inference = NeuronKit.inferLatticeAnchor("chemistry")
        XCTAssertFalse(inference.code.isEmpty)
        XCTAssertNotNil(inference.wikidataQID)
        XCTAssertEqual(
            inference.enrichmentStatusBits,
            EnrichmentStatus.qidCompleted.rawValue
        )
    }

    func testInferenceCarriesCurrentPipelineMode() {
        let inference = NeuronKit.inferLatticeAnchor("any term")
        XCTAssertEqual(
            inference.pipelineMode,
            NeuronKit.linguisticPipelineMode
        )
    }
}
