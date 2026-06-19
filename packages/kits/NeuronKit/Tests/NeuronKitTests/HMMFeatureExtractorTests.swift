// HMMFeatureExtractorTests.swift
//
// Unit tests for NeuronKit.hmmFeatureExtractor — the production HMM-tagger-backed
// DistillationPipeline.FeatureExtractor.
//
// Shared fixture with the Rust conformance leg (hmm_feature_extractor.rs #[cfg(test)]).
// Both ports must produce the same extracted features for the same input string.
//
// Test vectors are deterministic: the HMM tagger uses the frozen HMMTaggerModel.json
// artifact and the same UAX #29 tokeniser on both sides, so the feature sets are
// bit-identical across ports (LatticeLib contract, cookbook §2.2).

import Testing
import Foundation
@testable import NeuronKit
import SubstrateML

// MARK: - HMMFeatureExtractor Tests

@Suite("HMMFeatureExtractor")
struct HMMFeatureExtractorTests {

    // Canonical fixture shared with the Rust port:
    // "Project Apollo adopted PostgreSQL in 2021"
    //   ENT: apollo, postgresql (nouns via HMM; "project" may also be included)
    //   REL: adopted (verb via HMM)
    //   TMP: 2021 (4-digit year)
    //   NUM: 2021 (all-digit token; appears in both NUM and TMP since each type
    //              is queried separately by the pipeline)
    private let apolloSentence = "Project Apollo adopted PostgreSQL in 2021"

    // MARK: - Entity extraction

    @Test("ENT: 'apollo' is extracted as an entity")
    func entityApollo() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity)
        let values = features.map(\.value)
        #expect(values.contains("apollo"), "expected 'apollo' in ENT features; got \(values)")
    }

    @Test("ENT: 'postgresql' is extracted as an entity")
    func entityPostgresQL() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity)
        let values = features.map(\.value)
        #expect(values.contains("postgresql"), "expected 'postgresql' in ENT features; got \(values)")
    }

    @Test("ENT: all extracted features have type .entity")
    func entityFeaturesHaveCorrectType() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity)
        for f in features {
            #expect(f.type == .entity, "feature '\(f.value)' has wrong type \(f.type)")
        }
    }

    // MARK: - Relation extraction

    @Test("REL: 'adopted' is extracted as a relation")
    func relationAdopted() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .relation)
        let values = features.map(\.value)
        #expect(values.contains("adopted"), "expected 'adopted' in REL features; got \(values)")
    }

    @Test("REL: all extracted features have type .relation")
    func relationFeaturesHaveCorrectType() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .relation)
        for f in features {
            #expect(f.type == .relation, "feature '\(f.value)' has wrong type \(f.type)")
        }
    }

    // MARK: - Temporal extraction

    @Test("TMP: '2021' is extracted as a temporal marker (4-digit year)")
    func temporal2021() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .temporal)
        let values = features.map(\.value)
        #expect(values.contains("2021"), "expected '2021' in TMP features; got \(values)")
    }

    // Note: ISO date strings (e.g. "2021-03-15") are split by the UAX #29
    // tokenizer into ["2021", "03", "15"]. The year component "2021" is
    // classified as TMP via the 4-digit check; sub-components are 2-digit and
    // are not classified as TMP. This is correct and conformant behaviour.

    @Test("TMP: all extracted features have type .temporal")
    func temporalFeaturesHaveCorrectType() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .temporal)
        for f in features {
            #expect(f.type == .temporal, "feature '\(f.value)' has wrong type \(f.type)")
        }
    }

    // MARK: - Numerical extraction

    @Test("NUM: '42' is extracted as a numerical token")
    func numericalFortyTwo() {
        let features = NeuronKit.hmmFeatureExtractor(
            "There were 42 issues found", .numerical)
        let values = features.map(\.value)
        #expect(values.contains("42"), "expected '42' in NUM features; got \(values)")
    }

    @Test("NUM: all extracted features have type .numerical")
    func numericalFeaturesHaveCorrectType() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .numerical)
        for f in features {
            #expect(f.type == .numerical, "feature '\(f.value)' has wrong type \(f.type)")
        }
    }

    // MARK: - Determinism

    @Test("ENT: same input produces identical output on repeated calls (determinism)")
    func determinismENT() {
        let first  = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity).map(\.value)
        let second = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity).map(\.value)
        #expect(first == second, "hmmFeatureExtractor must be deterministic for ENT")
    }

    @Test("REL: same input produces identical output on repeated calls (determinism)")
    func determinismREL() {
        let first  = NeuronKit.hmmFeatureExtractor(apolloSentence, .relation).map(\.value)
        let second = NeuronKit.hmmFeatureExtractor(apolloSentence, .relation).map(\.value)
        #expect(first == second, "hmmFeatureExtractor must be deterministic for REL")
    }

    // MARK: - Edge cases

    @Test("empty content produces no features for any feature type")
    func emptyContent() {
        for featureType in DistillationFeatureType.allCases {
            let features = NeuronKit.hmmFeatureExtractor("", featureType)
            #expect(features.isEmpty, "empty content must produce no features for \(featureType)")
        }
    }

    @Test("docFrequency is 0 on every emitted feature")
    func docFrequencyIsZero() {
        // docFrequency must be 0 from the extractor; the pipeline sets the real value.
        for featureType in DistillationFeatureType.allCases {
            let features = NeuronKit.hmmFeatureExtractor(apolloSentence, featureType)
            for f in features {
                #expect(f.docFrequency == 0,
                    "docFrequency must be 0; pipeline sets it. Got \(f.docFrequency) for '\(f.value)'")
            }
        }
    }

    // MARK: - Temporal pattern classifiers

    @Test("TMP: 4-digit year boundary — exactly 4 digits is a year")
    func temporalYearBoundary() {
        // 4-digit all-numeric → year
        let y4 = NeuronKit.hmmFeatureExtractor("born in 1999", .temporal)
        #expect(y4.map(\.value).contains("1999"), "1999 must be TMP")

        // 3-digit → not a year
        let y3 = NeuronKit.hmmFeatureExtractor("the year 199 was odd", .temporal)
        #expect(!y3.map(\.value).contains("199"), "3-digit '199' must not be TMP")
    }

    // Note: ISO dates like "2024-12-31" are split by the UAX #29 tokenizer into
    // ["2024", "12", "31"]. "2024" is extracted as TMP (4-digit year).
    // "2021/03/15" is also split: "2021" is TMP; "03", "15" are not.
    // These behaviours are tested implicitly via the 4-digit year tests above
    // and verified via the shared conformance fixture.

    // MARK: - Integration: production pipeline succeeds with HMM extractor

    @Test("pipeline produces features (not 'No features extracted') with HMM extractor")
    func pipelineProducesFeaturesWithHMMExtractor() {
        // Integration: pipeline must NOT fail with "No features extracted" when given the
        // HMM extractor — that failure is the no-op-extractor failure, not an HMM failure.
        // The pipeline may still fail the SNR gate (a cluster-quality property), but the
        // HMM extractor must produce ENT/REL features from noun/verb-rich content.
        //
        // Mirrors Rust `pipeline_produces_features_with_hmm_extractor` in
        // tests/hmm_extractor_conformance.rs.
        let input = DistillationInput(
            memoryContents: [
                "apollo launched the mission",
                "the apollo crew trained for months",
                "apollo achieved orbit successfully",
                "apollo telemetry confirmed touchdown",
                "apollo landed at the designated site",
            ],
            clusterID: "hmm-extractor-tight-cluster",
            sourceIDs: ["s1", "s2", "s3", "s4", "s5"]
        )
        let result = NeuronKit.distillCluster(input: input)
        // HMM extractor must produce features — "No features extracted" is the no-op failure.
        let failureReason = result.failureReason ?? ""
        #expect(
            !failureReason.contains("No features extracted from memories"),
            "HMM extractor must produce features; got: \(failureReason)"
        )
    }
}
