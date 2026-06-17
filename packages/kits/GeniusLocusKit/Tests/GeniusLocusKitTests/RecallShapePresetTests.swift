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
        #expect(RecallShape.presetNames.count == 19)
    }

    @Test("precise amplifies lexical + field and narrows the frontier")
    func precise() throws {
        let s = try #require(RecallShape.preset("precise"))
        #expect(s.weight(for: "bm25") > 1.0)
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) > 1.0)
        #expect(s.weight(for: "dense") > 1.0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }

    @Test("conceptual amplifies distributional lanes and damps the keyword lane")
    func conceptual() throws {
        let s = try #require(RecallShape.preset("conceptual"))
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
        #expect(s.weight(for: RecallShape.DenseSignal.ppmi) > 1.0)
        #expect(s.weight(for: RecallShape.DenseSignal.lsa) > 1.0)
        #expect(s.weight(for: RecallShape.DenseSignal.nmf) > 1.0)
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
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) > 1.0)
        #expect(s.weight(for: "dense") == 0.0)
        #expect(s.weight(for: "hamming") == 0.0)
    }

    @Test("not_lexical excludes keyword + field, leaves others neutral")
    func notLexical() throws {
        let s = try #require(RecallShape.preset("not_lexical"))
        #expect(s.weight(for: "bm25") == 0.0)
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) == 0.0)
        #expect(s.weight(for: "locus") == 1.0)
    }

    @Test("associative amplifies RI + NMF and widens")
    func associative() throws {
        let s = try #require(RecallShape.preset("associative"))
        #expect(s.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
        #expect(s.weight(for: RecallShape.DenseSignal.nmf) > 1.0)
        #expect(s.effectiveFrontierK(engineDefault: 64) == RecallShape.frontierKCeiling)
    }

    @Test("consensus forwards every dense signal and narrows")
    func consensus() throws {
        let s = try #require(RecallShape.preset("consensus"))
        for key in RecallShape.DenseSignal.all {
            #expect(s.weight(for: key) > 0.0)
        }
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) > 0.0)
        #expect(s.effectiveFrontierK(engineDefault: 200) == RecallShape.frontierKFloor)
    }

    @Test("forward presets isolate one dense signal, excluding the siblings")
    func forwardPresets() throws {
        let ri = try #require(RecallShape.preset("ri_forward"))
        #expect(ri.weight(for: RecallShape.DenseSignal.randomIndexing) > 1.0)
        #expect(ri.weight(for: RecallShape.DenseSignal.ppmi) == 0.0)
        #expect(ri.weight(for: RecallShape.DenseSignal.lsa) == 0.0)
        #expect(ri.weight(for: RecallShape.DenseSignal.nmf) == 0.0)

        let lsa = try #require(RecallShape.preset("lsa_forward"))
        #expect(lsa.weight(for: RecallShape.DenseSignal.lsa) > 1.0)
        #expect(lsa.weight(for: RecallShape.DenseSignal.randomIndexing) == 0.0)
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

    @Test("anti_redundant inverts the FDC lane without suppressing it")
    func antiRedundant() throws {
        let s = try #require(RecallShape.preset("anti_redundant"))
        #expect(s.isAntiSimilar(RecallShape.DenseSignal.fdc))
        #expect(!s.isAntiSimilar(RecallShape.DenseSignal.lsa))
        // Distinct from a negative weight — the lane stays at the neutral default.
        #expect(s.weight(for: RecallShape.DenseSignal.fdc) == 1.0)
    }

    @Test("leave-one-out is reachable by zeroing one dense lane")
    func leaveOneOut() throws {
        let base = try #require(RecallShape.preset("consensus"))
        var weights = base.laneWeights
        weights[RecallShape.DenseSignal.lsa] = 0
        let ablated = RecallShape(laneWeights: weights, frontierK: base.frontierK)
        #expect(ablated.weight(for: RecallShape.DenseSignal.lsa) == 0.0)
        #expect(ablated.weight(for: RecallShape.DenseSignal.ppmi) > 0.0)
    }
}
