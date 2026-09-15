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
        // Roster: 26 base presets + 7 whole-record (conceptual, associative, consensus,
        // ri_forward, anti_redundant_ri, float-l2, float-dot) + 2 LSA (lsa_forward,
        // anti_redundant_lsa) = 35. Dense families (PPMI/NMF/FDC) are retired.
        let retiredPresets = ["ppmi_forward", "nmf_forward", "anti_redundant_nmf"]
        #expect(RecallShape.presetNames.count == 35)
        for retired in retiredPresets {
            #expect(!RecallShape.presetNames.contains(retired), "\(retired) is retired (dense families removed)")
            #expect(RecallShape.preset(retired) == nil)
            #expect(RecallShape.presetDescription(retired).isEmpty)
        }
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
        #expect(s.weight(for: "dense") > 1.0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }

    @Test("conceptual amplifies distributional lanes and damps the keyword lane")
    func conceptual() throws {
        let s = try #require(RecallShape.preset("conceptual"))
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
        let bm25 = s.weight(for: "bm25")
        #expect(bm25 < 1.0 && bm25 > 0.0)
    }

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
        #expect(s.weight(for: "dense") == 0.0)
        #expect(s.weight(for: "hamming") == 0.0)
    }

    @Test("not_lexical excludes keyword + field, leaves others neutral")
    func notLexical() throws {
        let s = try #require(RecallShape.preset("not_lexical"))
        #expect(s.weight(for: "bm25") == 0.0)
        #expect(s.weight(for: "locus") == 1.0)
    }

    @Test("associative amplifies RI + NMF and widens")
    func associative() throws {
        let s = try #require(RecallShape.preset("associative"))
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
        #expect(s.effectiveFrontierK(engineDefault: 64) == RecallShape.frontierKCeiling)
    }

    @Test("consensus forwards every dense signal and narrows")
    func consensus() throws {
        let s = try #require(RecallShape.preset("consensus"))
        for key in RecallShape.DenseSignal.all {
            #expect(s.weight(for: key) > 0.0)
        }
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }

    @Test("forward presets isolate one dense signal, excluding the siblings")
    func forwardPresets() throws {
        let ri = try #require(RecallShape.preset("ri_forward"))
        #expect(ri.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
        // RI is the only live family: nothing to exclude.
        #expect(ri.laneWeights == [RecallShape.DenseSignal.randomIndexing: 1.5])
    }

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

    @Test("leave-one-out is reachable by zeroing one dense lane")
    func leaveOneOut() throws {
        let base = try #require(RecallShape.preset("consensus"))
        var weights = base.laneWeights
        weights[RecallShape.DenseSignal.randomIndexing] = 0
        let ablated = RecallShape(laneWeights: weights, frontierK: base.frontierK)
        #expect(ablated.weight(for: RecallShape.DenseSignal.randomIndexing) == 0.0)
        #expect(ablated.weight(for: "dense") == 1.0)
    }

    // MARK: - Per-signal anti-similarity presets

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

    @Test("anti_redundant_lsa inverts LSA to farthest and suppresses BM25/Hamming")
    func antiRedundantLSA() throws {
        let s = try #require(RecallShape.preset("anti_redundant_lsa"))
        #expect(s.isAntiSimilar(RecallShape.DenseSignal.lsa))
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.randomIndexing))
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.encoder))
        #expect(s.weight(for: RecallShape.DenseSignal.lsa) == 1.0)
        #expect(s.weight(for: "bm25") < 0)
        #expect(s.weight(for: "hamming") < 0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
        #expect(!RecallShape.presetDescription("anti_redundant_lsa").isEmpty)
    }


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
        #expect(s.antiSimilarLanes.isEmpty)
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
        #expect(s.antiSimilarLanes.isEmpty)
        #expect(s.frontierK == nil)
        #expect(!RecallShape.presetDescription("field_preference").isEmpty)
    }

    // MARK: - Float-lane metric presets

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
}
