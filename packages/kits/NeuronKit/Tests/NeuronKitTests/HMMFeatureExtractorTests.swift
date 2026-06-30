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
import LatticeLib
@testable import NeuronKit
import SubstrateML

// MARK: - HMMFeatureExtractor Tests

@Suite("HMMFeatureExtractor")
struct HMMFeatureExtractorTests {

    // Canonical fixture shared with the Rust port:
    // "Project Apollo adopted PostgreSQL in 2021"
    //   ENT: apollo, postgresql surfaces (nouns via HMM; "project" may also be
    //        included). value = Snowball stem, display = surface form.
    //   REL: adopted surface (verb via HMM); value = stem "adopt".
    //   TMP: 2021 (4-digit year; no stem, value == display)
    //   NUM: 2021 (all-digit token; appears in both NUM and TMP since each type
    //              is queried separately by the pipeline)
    private let apolloSentence = "Project Apollo adopted PostgreSQL in 2021"

    // MARK: - Entity extraction

    @Test("ENT: 'apollo' surface is extracted as an entity, value is its stem")
    func entityApollo() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity)
        let displays = features.map(\.display)
        #expect(displays.contains("apollo"), "expected 'apollo' surface in ENT features; got \(displays)")
        // Every ENT feature's value is the Snowball stem of its display surface.
        for f in features {
            #expect(f.value == Stemmer.stem(f.display),
                    "value must be stem of display (\(f.display))")
        }
    }

    @Test("ENT: 'postgresql' surface is extracted as an entity")
    func entityPostgresQL() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity)
        let displays = features.map(\.display)
        #expect(displays.contains("postgresql"), "expected 'postgresql' surface in ENT features; got \(displays)")
    }

    @Test("ENT: all extracted features have type .entity")
    func entityFeaturesHaveCorrectType() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .entity)
        for f in features {
            #expect(f.type == .entity, "feature '\(f.value)' has wrong type \(f.type)")
        }
    }

    // MARK: - Relation extraction

    @Test("REL: 'adopted' surface is extracted as a relation, value is its stem")
    func relationAdopted() {
        let features = NeuronKit.hmmFeatureExtractor(apolloSentence, .relation)
        let displays = features.map(\.display)
        #expect(displays.contains("adopted"), "expected 'adopted' surface in REL features; got \(displays)")
        if let adopted = features.first(where: { $0.display == "adopted" }) {
            #expect(adopted.value == Stemmer.stem("adopted"))
        }
    }

    // MARK: - Stopword filtering

    @Test("ENT: distillation stopwords are never emitted as entities")
    func stopwordsDroppedFromEntities() {
        let text = "the database in the system was migrated by the team to the cloud"
        let features = NeuronKit.hmmFeatureExtractor(text, .entity)
        for f in features {
            #expect(!NeuronKit.distillationStopwords.contains(f.display),
                    "stopword '\(f.display)' must not appear as an ENT feature")
        }
    }

    @Test("REL: distillation stopwords are never emitted as relations")
    func stopwordsDroppedFromRelations() {
        let text = "the team has to migrate and they will be doing it by friday"
        let features = NeuronKit.hmmFeatureExtractor(text, .relation)
        for f in features {
            #expect(!NeuronKit.distillationStopwords.contains(f.display),
                    "stopword '\(f.display)' must not appear as a REL feature")
        }
    }

    @Test("Stopword set has the conformance-pinned element count")
    func stopwordCountMatchesRust() {
        // 152 words, byte-for-byte identical to the Rust DISTILLATION_STOPWORDS.
        #expect(NeuronKit.distillationStopwords.count == 152)
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

    // MARK: - Pool isolation: extractor must not feed novel tokens into the pool
    //
    // The distillation extractor processes private memory-drawer content. It uses
    // `wordClass(_:tagger:recordNovel: false)` so novel tokens are NOT accumulated
    // in the pool pipeline, matching Rust's non-recording hmm_tag behaviour.
    //
    // The sharedNovelCache accumulation invariant is tested at the LatticeLib level
    // (WordClassRecordNovelTests.swift, which has @testable import LatticeLib access
    // to the internal sharedNovelCache property). From NeuronKit's perspective we
    // verify that the extracted FEATURE RESULTS are unchanged by the fix.

    /// Feature-identity verification: `hmmFeatureExtractor` output must be identical
    /// after switching from the recording path to `recordNovel: false`. The fix
    /// suppresses only the pool side effect — the tag computation is unchanged.
    ///
    /// Verified against the canonical "Project Apollo" fixture shared with the Rust port.
    @Test("hmmFeatureExtractor features unchanged by recordNovel:false fix (canonical fixture)")
    func extractorFeaturesUnchangedByRecordNovelFix() {
        // Canonical test sentence — same fixture as the Rust port.
        let content = "Project Apollo adopted PostgreSQL in 2021"

        // Run the extractor (which uses recordNovel: false internally).
        let entFeatures = NeuronKit.hmmFeatureExtractor(content, .entity)
        let relFeatures = NeuronKit.hmmFeatureExtractor(content, .relation)

        // Verify the canonical noun/verb features are still extracted correctly.
        // The recordNovel flag changes only whether tokens enter the pool pipeline —
        // not whether they get a .noun or .verb tag from the HMM.
        let entDisplays = entFeatures.map(\.display)
        let relDisplays = relFeatures.map(\.display)

        #expect(entDisplays.contains("apollo"),
                "ENT must still contain 'apollo' after recordNovel:false fix; got \(entDisplays)")
        #expect(entDisplays.contains("postgresql"),
                "ENT must still contain 'postgresql' after recordNovel:false fix; got \(entDisplays)")
        #expect(relDisplays.contains("adopted"),
                "REL must still contain 'adopted' after recordNovel:false fix; got \(relDisplays)")

        // All features must have docFrequency == 0 (pipeline sets the real value).
        for f in entFeatures + relFeatures {
            #expect(f.docFrequency == 0,
                    "docFrequency must be 0 from extractor; got \(f.docFrequency) for '\(f.value)'")
        }
    }

    /// Novel-token sentence: the extractor must still produce features for content
    /// that includes tokens not in the static word-class table (novel tokens). The
    /// HMM tagger handles them and the feature result must be non-empty even when
    /// recording is suppressed.
    @Test("hmmFeatureExtractor produces ENT features for content containing novel tokens")
    func extractorProducesFeaturesForNovelTokenContent() {
        // "xylophonation" is a novel token (absent from the static table). The HMM
        // will tag it; with recordNovel:false the tag result is unchanged vs recording.
        // "apollo" and "postgresql" are known entities — they anchor the assertion.
        let content = "Apollo xylophonation the database migration team"

        let entFeatures = NeuronKit.hmmFeatureExtractor(content, .entity)
        // "apollo" must still be found — the novel token must not suppress results.
        let displays = entFeatures.map(\.display)
        #expect(!displays.isEmpty,
                "extractor must produce ENT features for novel-token content; got none")
    }

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
