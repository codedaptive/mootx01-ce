// RecallShapePresetTests.swift
//
// Tests for the named RecallShape preset roster (GLK-RECALL-SHAPE-PRESETS).
// Each preset resolves to its documented signed-weight shape; the roster is
// discoverable via `presetNames`; balanced/unknown resolve to nil. Mirrors the
// Rust recall_shape_presets.rs — both ports assert the same directions.
//
// We assert DIRECTION (forward >1, neutral ==1 via absence, exclude ==0), not
// the exact tunable magnitude — except where the magnitude IS the contract
// (0 = exclude). The optimizer owns the literal floats.

import Testing
import GeniusLocusKit

@Suite("RecallShape named preset roster")
struct RecallShapePresetTests {

    @Test("balanced resolves to nil (the absence of steering)")
    func balancedIsNil() {
        #expect(RecallShape.preset("balanced") == nil)
    }

    @Test("an unknown name resolves to nil, indistinguishable from balanced")
    func unknownIsNil() {
        #expect(RecallShape.preset("no-such-preset") == nil)
        #expect(RecallShape.preset("") == nil)
    }

    @Test("every roster name is discoverable and resolves (no silent no-op)")
    func rosterIsDiscoverable() {
        for name in RecallShape.presetNames {
            if name == "balanced" {
                #expect(RecallShape.preset(name) == nil)
            } else {
                #expect(RecallShape.preset(name) != nil, "preset \(name) must resolve")
            }
        }
        // Default roster: 26 presets. The WholeRecordDense build adds the
        // eight whole-record presets (conceptual, associative, consensus,
        // ri_forward, whole_record_baseline, anti_redundant_ri, float-l2,
        // float-dot) = 34; DenseFamilies adds ppmi/nmf_forward and
        // anti_redundant_nmf on top = 37; MOOTX01_LSA additionally adds
        // lsa_forward and anti_redundant_lsa = 39.
        let lsaPresets = ["lsa_forward", "anti_redundant_lsa"]
        let familyPresets = ["ppmi_forward", "nmf_forward", "anti_redundant_nmf"]
        let wholeRecordPresets = ["conceptual", "associative", "consensus", "ri_forward",
                                  "whole_record_baseline", "anti_redundant_ri", "float-l2", "float-dot"]
#if MOOTX01_DENSE_FAMILIES
#if MOOTX01_LSA
        #expect(RecallShape.presetNames.count == 39)
        _ = lsaPresets; _ = familyPresets; _ = wholeRecordPresets
#else
        #expect(RecallShape.presetNames.count == 37)
        for dark in lsaPresets {
            #expect(!RecallShape.presetNames.contains(dark), "\(dark) is dark without the LSA trait")
            #expect(RecallShape.preset(dark) == nil)
        }
        _ = familyPresets; _ = wholeRecordPresets
#endif
#elseif MOOTX01_WHOLE_RECORD_DENSE
        #expect(RecallShape.presetNames.count == 34)
        for dark in familyPresets {
            #expect(!RecallShape.presetNames.contains(dark), "\(dark) is dark without the DenseFamilies trait")
            #expect(RecallShape.preset(dark) == nil)
        }
        _ = wholeRecordPresets
#else
        #expect(RecallShape.presetNames.count == 26)
        for dark in familyPresets + wholeRecordPresets {
            #expect(!RecallShape.presetNames.contains(dark), "\(dark) is dark without the WholeRecordDense trait")
            #expect(RecallShape.preset(dark) == nil)
            #expect(RecallShape.presetDescription(dark).isEmpty)
        }
#endif
        // `cross_encoder` is reserved (sheet §8), not implemented: absent from
        // the roster and unresolvable, so the tool rejects it as unknown.
        #expect(!RecallShape.presetNames.contains("cross_encoder"))
        #expect(RecallShape.preset("cross_encoder") == nil)
    }

    @Test("signal:vector defaults to 0; every other key defaults to 1.0")
    func defaultWeights() {
        #expect(RecallShape.defaultWeight(for: RecallShape.SignalKey.vector) == 0)
        #expect(RecallShape.defaultWeight(for: "bm25") == 1.0)
        #expect(RecallShape.defaultWeight(for: RecallShape.SignalKey.encoder) == 1.0)
        let empty = RecallShape()
        #expect(empty.weight(for: RecallShape.SignalKey.vector) == 0)
        #expect(empty.weight(for: RecallShape.DenseSignal.encoder) == 1.0)
        #expect(RecallShape.DenseSignal.key(forModelID: "minilm-l6-v2-w60") == RecallShape.DenseSignal.encoder)
    }

    @Test("no_encoder skips the stage through signal:encoder only")
    func noEncoder() throws {
        let s = try #require(RecallShape.preset("no_encoder"))
        #expect(s.laneWeights == [RecallShape.SignalKey.encoder: 0])
        #expect(s.weight(for: RecallShape.SignalKey.vector) == 0, "the vector column stays at its default")
        #expect(!RecallShape.presetDescription("no_encoder").isEmpty)
    }

    @Test("precise amplifies lexical + field and narrows the frontier")
    func precise() throws {
        let s = try #require(RecallShape.preset("precise"))
        #expect(s.weight(for: "bm25") > 1.0)
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) > 1.0)
#endif
        #expect(s.weight(for: "dense") > 1.0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("conceptual amplifies distributional lanes and damps the keyword lane")
    func conceptual() throws {
        let s = try #require(RecallShape.preset("conceptual"))
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.ppmi) > 1.0)
#if MOOTX01_LSA
        #expect(s.weight(for: RecallShape.DenseSignal.lsa) > 1.0)
#endif // MOOTX01_LSA
        #expect(s.weight(for: RecallShape.DenseSignal.nmf) > 1.0)
#endif
        let bm25 = s.weight(for: "bm25")
        #expect(bm25 < 1.0 && bm25 > 0.0)
    }
#endif

    @Test("broad forwards all retrieval lanes and widens to the ceiling")
    func broad() throws {
        let s = try #require(RecallShape.preset("broad"))
        #expect(s.weight(for: "locus") > 1.0)
        #expect(s.weight(for: "bm25") > 1.0)
        #expect(s.weight(for: "hamming") > 1.0)
        #expect(s.weight(for: "dense") > 1.0)
        #expect(s.effectiveFrontierK(engineDefault: 64) == RecallShape.frontierKCeiling)
    }

    @Test("lexical excludes the vector lanes (==0, not merely absent)")
    func lexical() throws {
        let s = try #require(RecallShape.preset("lexical"))
        #expect(s.weight(for: "bm25") > 1.0)
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) > 1.0)
#endif
        #expect(s.weight(for: "dense") == 0.0)
        #expect(s.weight(for: "hamming") == 0.0)
    }

    @Test("not_lexical excludes keyword + field, leaves others neutral")
    func notLexical() throws {
        let s = try #require(RecallShape.preset("not_lexical"))
        #expect(s.weight(for: "bm25") == 0.0)
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) == 0.0)
#endif
        #expect(s.weight(for: "locus") == 1.0)
    }

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("associative amplifies RI + NMF and widens")
    func associative() throws {
        let s = try #require(RecallShape.preset("associative"))
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.nmf) > 1.0)
#endif
        #expect(s.effectiveFrontierK(engineDefault: 64) == RecallShape.frontierKCeiling)
    }
#endif

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("consensus forwards every dense signal and narrows")
    func consensus() throws {
        let s = try #require(RecallShape.preset("consensus"))
        for key in RecallShape.DenseSignal.all {
            #expect(s.weight(for: key) > 0.0)
        }
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) > 0.0)
#endif
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }
#endif

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("forward presets isolate one dense signal, excluding the siblings")
    func forwardPresets() throws {
        let ri = try #require(RecallShape.preset("ri_forward"))
        #expect(ri.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
#if MOOTX01_DENSE_FAMILIES
        #expect(ri.weight(for: RecallShape.DenseSignal.ppmi) == 0.0)
#if MOOTX01_LSA
        #expect(ri.weight(for: RecallShape.DenseSignal.lsa) == 0.0)
#endif // MOOTX01_LSA
        #expect(ri.weight(for: RecallShape.DenseSignal.nmf) == 0.0)
#if MOOTX01_LSA
        let lsa = try #require(RecallShape.preset("lsa_forward"))
        #expect(lsa.weight(for: RecallShape.DenseSignal.lsa) > 1.0)
        #expect(lsa.weight(for: RecallShape.DenseSignal.randomIndexing) == 0.0)
#endif // MOOTX01_LSA
#else
        // RI is the only live family: nothing to exclude.
        #expect(ri.laneWeights == [RecallShape.DenseSignal.randomIndexing: 1.5])
#endif
    }
#endif

    @Test("fast keeps the hamming lane only")
    func fast() throws {
        let s = try #require(RecallShape.preset("fast"))
        #expect(s.weight(for: "hamming") > 1.0)
        #expect(s.weight(for: "dense") == 0.0)
    }

    @Test("matrix-column presets amplify their column")
    func matrixColumns() throws {
        #expect(try #require(RecallShape.preset("structural")).weight(for: "locus") > 1.0)
        #expect(try #require(RecallShape.preset("temporal")).weight(for: "temporal") > 1.0)
        #expect(try #require(RecallShape.preset("connection")).weight(for: "graph") > 1.0)
        #expect(try #require(RecallShape.preset("field")).weight(for: "coOccurrence") > 1.0)
        #expect(try #require(RecallShape.preset("preference")).weight(for: "preference") > 1.0)
    }

    @Test("anti_redundant inverts FDC and suppresses BM25/Hamming lexical duplicates")
    func antiRedundant() throws {
        let s = try #require(RecallShape.preset("anti_redundant"))
#if MOOTX01_DENSE_FAMILIES
        // FDC lane is anti-similar (farthest-neighbour direction).
        #expect(s.isAntiSimilar(RecallShape.DenseSignal.fdc))
#if MOOTX01_LSA
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.lsa))
#endif // MOOTX01_LSA
        // FDC lane weight stays at 1.0 — the anti-similar flag flips direction, not magnitude.
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) == 1.0)
#elseif MOOTX01_WHOLE_RECORD_DENSE
        // FDC is dark: nothing is inverted, the suppression and narrow frontier remain.
        #expect(s.antiSimilarLanes.isEmpty)
#endif
        // BM25 and Hamming are suppressed so lexical near-duplicates cannot dominate.
        #expect(s.weight(for: "bm25") < 0)
        #expect(s.weight(for: "hamming") < 0)
        // Frontier narrowed to the floor so the engine does not haul a wide pool of duplicates.
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }

    @Test("session_hybrid amplifies bm25 + dense + temporal for session-granularity recall")
    func sessionHybrid() throws {
        let s = try #require(RecallShape.preset("session_hybrid"))
        // bm25 amplified — keyword matching for conversation fragments.
        #expect(s.weight(for: "bm25") > 1.0)
        // dense amplified — semantic similarity within the session window.
        #expect(s.weight(for: "dense") > 1.0)
        // temporal amplified — recency within the session window.
        #expect(s.weight(for: "temporal") > 1.0)
        // No lanes are excluded — session_hybrid is additive over balanced.
        #expect(s.weight(for: "locus") == 1.0)
        #expect(s.weight(for: "hamming") == 1.0)
        // Description is present in the catalog.
        #expect(!RecallShape.presetDescription("session_hybrid").isEmpty)
    }

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("leave-one-out is reachable by zeroing one dense lane")
    func leaveOneOut() throws {
        let base = try #require(RecallShape.preset("consensus"))
        var weights = base.laneWeights
#if MOOTX01_DENSE_FAMILIES
#if MOOTX01_LSA
        weights[RecallShape.DenseSignal.lsa] = 0
        let ablated = RecallShape(laneWeights: weights, frontierK: base.frontierK)
        #expect(ablated.weight(for: RecallShape.DenseSignal.lsa) == 0.0)
        #expect(ablated.weight(for: RecallShape.DenseSignal.ppmi) > 0.0)
#else
        weights[RecallShape.DenseSignal.ppmi] = 0
        let ablated = RecallShape(laneWeights: weights, frontierK: base.frontierK)
        #expect(ablated.weight(for: RecallShape.DenseSignal.ppmi) == 0.0)
        #expect(ablated.weight(for: RecallShape.DenseSignal.nmf) > 0.0)
#endif // MOOTX01_LSA
#else
        weights[RecallShape.DenseSignal.randomIndexing] = 0
        let ablated = RecallShape(laneWeights: weights, frontierK: base.frontierK)
        #expect(ablated.weight(for: RecallShape.DenseSignal.randomIndexing) == 0.0)
        #expect(ablated.weight(for: "dense") == 1.0)
#endif
    }
#endif

    // MARK: - Per-signal anti-similarity presets (WholeRecordDense build)

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("anti_redundant_ri inverts RI to farthest and suppresses BM25/Hamming")
    func antiRedundantRI() throws {
        let s = try #require(RecallShape.preset("anti_redundant_ri"))
        // RI lane inverted to farthest (anti-similar).
        #expect(s.isAntiSimilar(RecallShape.DenseSignal.randomIndexing))
        // Only RI is anti-similar.
        #expect(s.antiSimilarLanes == [RecallShape.DenseSignal.randomIndexing])
        // Anti-similar flag flips direction, not magnitude — RI weight stays at 1.0.
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) == 1.0)
        // BM25 and Hamming suppressed to prevent lexical near-duplicates dominating.
        #expect(s.weight(for: "bm25") < 0)
        #expect(s.weight(for: "hamming") < 0)
        // Frontier narrowed to floor for a tight, focused diversity pool.
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
        // Catalog description is present.
        #expect(!RecallShape.presetDescription("anti_redundant_ri").isEmpty)
    }

#if MOOTX01_LSA
    @Test("anti_redundant_lsa inverts LSA to farthest and suppresses BM25/Hamming")
    func antiRedundantLSA() throws {
        let s = try #require(RecallShape.preset("anti_redundant_lsa"))
        #expect(s.isAntiSimilar(RecallShape.DenseSignal.lsa))
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.randomIndexing))
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.fdc))
        #expect(s.weight(for: RecallShape.DenseSignal.lsa) == 1.0)
        #expect(s.weight(for: "bm25") < 0)
        #expect(s.weight(for: "hamming") < 0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
        #expect(!RecallShape.presetDescription("anti_redundant_lsa").isEmpty)
    }
#endif // MOOTX01_LSA

#if MOOTX01_DENSE_FAMILIES
    @Test("anti_redundant_nmf inverts NMF to farthest and suppresses BM25/Hamming")
    func antiRedundantNMF() throws {
        let s = try #require(RecallShape.preset("anti_redundant_nmf"))
        #expect(s.isAntiSimilar(RecallShape.DenseSignal.nmf))
#if MOOTX01_LSA
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.lsa))
#endif // MOOTX01_LSA
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.fdc))
        #expect(s.weight(for: RecallShape.DenseSignal.nmf) == 1.0)
        #expect(s.weight(for: "bm25") < 0)
        #expect(s.weight(for: "hamming") < 0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
        #expect(!RecallShape.presetDescription("anti_redundant_nmf").isEmpty)
    }
#endif
#endif // MOOTX01_WHOLE_RECORD_DENSE

    // MARK: - Multi-column matrix presets

    @Test("temporal_connection amplifies temporal + coOccurrence for matrixAware scoring")
    func temporalConnection() throws {
        let s = try #require(RecallShape.preset("temporal_connection"))
        // Both matrix columns amplified above neutral.
        #expect(s.weight(for: "temporal") > 1.0)
        #expect(s.weight(for: "coOccurrence") > 1.0)
        // No lanes excluded or anti-similar — purely additive over balanced.
        #expect(s.weight(for: "locus") == 1.0)
        #expect(s.weight(for: "bm25") == 1.0)
#if MOOTX01_WHOLE_RECORD_DENSE
        #expect(s.antiSimilarLanes.isEmpty)
#endif
        // No frontier override — the engine formula applies.
        #expect(s.frontierK == nil)
        #expect(!RecallShape.presetDescription("temporal_connection").isEmpty)
    }

    @Test("field_preference amplifies fieldFit + preference for matrixAware scoring")
    func fieldPreference() throws {
        let s = try #require(RecallShape.preset("field_preference"))
        // Both matrix columns amplified above neutral.
        #expect(s.weight(for: "fieldFit") > 1.0)
        #expect(s.weight(for: "preference") > 1.0)
        // No lanes excluded or anti-similar — purely additive over balanced.
        #expect(s.weight(for: "locus") == 1.0)
        #expect(s.weight(for: "temporal") == 1.0)
#if MOOTX01_WHOLE_RECORD_DENSE
        #expect(s.antiSimilarLanes.isEmpty)
#endif
        #expect(s.frontierK == nil)
        #expect(!RecallShape.presetDescription("field_preference").isEmpty)
    }

    // MARK: - The audition baseline (WholeRecordDense build)

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("whole_record_baseline forwards every held whole-record signal at 1.0 over the default frontier")
    func wholeRecordBaseline() throws {
        let s = try #require(RecallShape.preset("whole_record_baseline"))
        for key in RecallShape.DenseSignal.all {
            #expect(s.weight(for: key) == 1.0)
        }
#if MOOTX01_DENSE_FAMILIES
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) == 1.0)
#endif
        // Nothing else is steered: the fusion equals this build's nil shape.
        #expect(s.weight(for: "bm25") == 1.0)
        #expect(s.frontierK == nil)
        #expect(s.antiSimilarLanes.isEmpty)
        #expect(!RecallShape.presetDescription("whole_record_baseline").isEmpty)
    }
#endif

    // MARK: - Float-lane metric presets

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("float-l2 sets floatMetric to l2 and leaves all other fields at their defaults")
    func floatL2() throws {
        let s = try #require(RecallShape.preset("float-l2"))
        // The ONLY change from balanced is the float-lane metric.
        #expect(s.floatMetric == "l2")
        // All lane weights stay neutral — no fusion steering.
        #expect(s.laneWeights.isEmpty)
        // Anti-similar set stays empty — no direction inversion.
        #expect(s.antiSimilarLanes.isEmpty)
        // No frontier override — engine default applies.
        #expect(s.frontierK == nil)
        // Binary metric unchanged from the default.
        #expect(s.binaryMetric == "hamming")
        // Description is present in the catalog.
        #expect(!RecallShape.presetDescription("float-l2").isEmpty)
    }
#endif

#if MOOTX01_WHOLE_RECORD_DENSE
    @Test("float-dot sets floatMetric to dot and leaves all other fields at their defaults")
    func floatDot() throws {
        let s = try #require(RecallShape.preset("float-dot"))
        // The ONLY change from balanced is the float-lane metric.
        #expect(s.floatMetric == "dot")
        // All lane weights stay neutral — no fusion steering.
        #expect(s.laneWeights.isEmpty)
        // Anti-similar set stays empty — no direction inversion.
        #expect(s.antiSimilarLanes.isEmpty)
        // No frontier override — engine default applies.
        #expect(s.frontierK == nil)
        // Binary metric unchanged from the default.
        #expect(s.binaryMetric == "hamming")
        // Description is present in the catalog.
        #expect(!RecallShape.presetDescription("float-dot").isEmpty)
    }
#endif
}
