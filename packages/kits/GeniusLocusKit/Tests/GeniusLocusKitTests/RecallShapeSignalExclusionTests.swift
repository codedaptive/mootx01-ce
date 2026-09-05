// RecallShapeSignalExclusionTests.swift
//
// Behavioural tests for the `signal:*` column-budget keys (COL-1) in the
// unionBest `.matrixAware` weighted score. Mirrors
// rust/tests/recall_shape_signal_exclusion_parity.rs.
//
//   (a) `signal:graph` = 0 with a constant GraphCache changes fused finals
//       relative to the neutral recall AND, for every shared drawer, reads at or
//       above the per-lane `graph` = 0 final — exclusion redistributes the graph
//       budget over the remaining columns where per-lane zeroing only drops it;
//       strictly above for at least one drawer.
//   (b) `signal:agreement` = 0 reads strictly below the neutral final for every
//       hit (every hit carries at least one source bit, so the bonus was > 0).
//   (c) nil shape == a shape with every `signal:*` key at 1.0, BYTE-IDENTICAL
//       (the back-compat contract extends to the new namespace).
//   (d) the six ablation presets each set exactly one `signal:*` key at 0.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("RecallShape signal:* column exclusion in unionBest (COL-1)", .serialized)
struct RecallShapeSignalExclusionTests {

    private struct ConstantGraphCache: GraphCache {
        let score: Float
        func graphScore(for drawerID: String) -> Float { score }
    }

    private func openTwoDrawerEstate(owner ownerID: String)
        async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let f1 = CaptureFrame(content: "signal exclusion alpha content", channel: .typed,
                              room: "signal-exclusion-tests", latticeAnchor: .udc("000"),
                              addedBy: "signal-exclusion-tests", embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, f1)
        let f2 = CaptureFrame(content: "signal exclusion beta content", channel: .voiced,
                              room: "signal-exclusion-tests", latticeAnchor: .udc("000"),
                              addedBy: "signal-exclusion-tests", embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, f2)
        return (kit: kit, handle: handle)
    }

    private func matrixReq(shape: RecallShape?) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: 10,
            fallback: .failClosed, origin: .internal, recallShape: shape)
    }

    private func finals(_ result: GLKRecallResult) -> [String: Float] {
        Dictionary(uniqueKeysWithValues: result.hits.map { ($0.id, $0.score.final) })
    }

    @Test("(a) signal:graph = 0 excludes AND redistributes: at or above per-lane graph = 0")
    func signalGraphExclusionRedistributes() async throws {
        let (kit, handle) = try await openTwoDrawerEstate(owner: "signal-graph-owner")
        await kit.registerGraphCache(ConstantGraphCache(score: 0.8), for: handle)

        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let laneZero = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["graph": 0.0])))
        let excluded = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: [RecallShape.SignalKey.graph: 0.0])))

        let neutralFinals = finals(neutral)
        let laneZeroFinals = finals(laneZero)
        #expect(!excluded.hits.isEmpty)
        var changedFromNeutral = false
        var strictlyAboveLaneZero = false
        for hit in excluded.hits {
            if let before = neutralFinals[hit.id], before != hit.score.final { changedFromNeutral = true }
            if let dropped = laneZeroFinals[hit.id] {
                #expect(hit.score.final >= dropped,
                    "redistributed exclusion must not read below per-lane zeroing for \(hit.id)")
                if hit.score.final > dropped { strictlyAboveLaneZero = true }
            }
        }
        #expect(changedFromNeutral, "excluding the graph column must change a fused final")
        #expect(strictlyAboveLaneZero,
            "redistribution must lift at least one included-column final above per-lane zeroing")
        try await kit.close(handle)
    }

    @Test("(b) signal:agreement = 0 reads strictly below neutral for every hit")
    func signalAgreementExclusionLowersEveryFinal() async throws {
        let (kit, handle) = try await openTwoDrawerEstate(owner: "signal-agreement-owner")

        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let noBonus = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: [RecallShape.SignalKey.agreement: 0.0])))

        let neutralFinals = finals(neutral)
        #expect(!noBonus.hits.isEmpty)
        for hit in noBonus.hits {
            let before = try #require(neutralFinals[hit.id])
            #expect(hit.score.final < before, "dropping the agreement bonus must lower \(hit.id)")
        }
        try await kit.close(handle)
    }

    @Test("(c) nil shape == all signal:* keys at 1.0 (byte-identical)")
    func nilEqualsAllOnesSignalKeys() async throws {
        let (kit, handle) = try await openTwoDrawerEstate(owner: "signal-ones-owner")
        await kit.registerGraphCache(ConstantGraphCache(score: 0.8), for: handle)

        let ones = Dictionary(uniqueKeysWithValues: RecallShape.SignalKey.all.map { ($0, Float(1.0)) })
        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let explicit = try await kit.recall(handle, matrixReq(shape: RecallShape(laneWeights: ones)))

        #expect(neutral.hits.map(\.id) == explicit.hits.map(\.id))
        #expect(neutral.hits.map(\.score.final) == explicit.hits.map(\.score.final))
        try await kit.close(handle)
    }

    /// COL-1 Part C: on an estate with no MatrixTier, GraphCache or
    /// PreferenceStore the five cold-path columns carry no measurement, so the
    /// director excludes fieldFit, matrix, graph and preference automatically and
    /// redistributes their budget. Two mutation controls against the pre-COL-1
    /// order (zero columns kept their budget):
    ///   1. a nil shape is BYTE-IDENTICAL to a shape that excludes exactly those
    ///      four columns explicitly;
    ///   2. the top hit (locus-only: no query text, so bm25/Hamming/dense are
    ///      dark) exceeds the pre-COL-1 ceiling `weights.locus × 1.0 + agreement`
    ///      ≤ 0.25 + 0.05 = 0.30; with the empty columns' budget redistributed it
    ///      reads 0.4237931, identical on both ports.
    @Test("(e) empty-store columns are excluded automatically (Part C)")
    func absentColumnsExcludedAutomatically() async throws {
        let (kit, handle) = try await openTwoDrawerEstate(owner: "signal-absent-owner")
        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let explicit = try await kit.recall(handle, matrixReq(shape: RecallShape(laneWeights: [
            RecallShape.SignalKey.fieldFit: 0, RecallShape.SignalKey.matrix: 0,
            RecallShape.SignalKey.graph: 0, RecallShape.SignalKey.preference: 0,
        ])))
        let a = neutral.hits.map(\.score.final)
        let b = explicit.hits.map(\.score.final)
        #expect(!a.isEmpty)
        #expect(a == b, "automatic exclusion must equal explicit exclusion byte for byte")
        let top = a.max() ?? 0
        #expect(top > 0.30,
            "top final must exceed the pre-COL-1 ceiling 0.30 (redistribution lifts it to ~0.42); got \(top)")
        try await kit.close(handle)
    }

    /// COL-1 Part C: the locus column is the candidate's rank in the frame's
    /// filedAt DESC slice. With query text it measures recency, not relevance,
    /// so the director excludes it automatically (nil == explicit `signal:locus`
    /// = 0, byte-identical). Without query text the recency rank is the
    /// requested ordering and the column stays (nil != explicit exclusion); the
    /// second pair is the mutation control (pre-COL-1 the first pair differed too).
    @Test("(f) locus column is excluded for text queries only (Part C)")
    func locusExcludedForTextQueriesOnly() async throws {
        let (kit, handle) = try await openTwoDrawerEstate(owner: "signal-locus-text-owner")
        func textReq(_ shape: RecallShape?) -> GLKRecallRequest {
            GLKRecallRequest(
                frame: RecallFrame(filterChain: [], hydrationLevel: .structured,
                                   ordering: .byCaptureTimeDesc),
                mode: .unionBest, scoring: .matrixAware, limit: 10,
                fallback: .allowDegraded, queryText: "alpha content",
                origin: .internal, recallShape: shape)
        }
        let a = try await kit.recall(handle, textReq(nil)).hits.map(\.score.final)
        let b = try await kit.recall(handle, textReq(RecallShape(laneWeights: [RecallShape.SignalKey.locus: 0])))
            .hits.map(\.score.final)
        #expect(!a.isEmpty)
        #expect(a == b, "text query: automatic locus exclusion must equal explicit exclusion")
        let c = try await kit.recall(handle, matrixReq(shape: nil)).hits.map(\.score.final)
        let d = try await kit.recall(handle, matrixReq(shape: RecallShape(laneWeights: [RecallShape.SignalKey.locus: 0])))
            .hits.map(\.score.final)
        #expect(c != d, "structured browse: the locus recency rank must stay in the score")
        try await kit.close(handle)
    }

    @Test("(g) no_vector / no_bm25 presets exclude only the scoring column: the candidate set survives")
    func candidateLanePresetsKeepTheirCandidates() async throws {
        let (kit, handle) = try await openTwoDrawerEstate(owner: "signal-candidate-lane-owner")
        func textReq(_ shape: RecallShape?) -> GLKRecallRequest {
            GLKRecallRequest(
                frame: RecallFrame(filterChain: [], hydrationLevel: .structured,
                                   ordering: .byCaptureTimeDesc),
                mode: .unionBest, scoring: .matrixAware, limit: 10,
                fallback: .allowDegraded, queryText: "alpha content",
                origin: .internal, recallShape: shape)
        }
        let neutral = try await kit.recall(handle, textReq(nil))
        #expect(!neutral.hits.isEmpty)
        for (name, key) in [("no_vector", RecallShape.SignalKey.vector), ("no_bm25", RecallShape.SignalKey.bm25)] {
            let preset = try #require(RecallShape.preset(name))
            let viaPreset = try await kit.recall(handle, textReq(preset))
            let viaKey = try await kit.recall(handle, textReq(RecallShape(laneWeights: [key: 0])))
            // The preset is exactly the explicit key at 0: same hits, same finals.
            #expect(viaPreset.hits.map(\.id) == viaKey.hits.map(\.id), "\(name) must equal explicit \(key) = 0")
            #expect(viaPreset.hits.map(\.score.final) == viaKey.hits.map(\.score.final))
            // Exclusion drops a scoring column, never the lane's candidates: the
            // hit SET is the neutral set (order may change, membership may not).
            #expect(Set(viaPreset.hits.map(\.id)) == Set(neutral.hits.map(\.id)),
                "\(name) must keep every candidate the lanes produced")
        }
        try await kit.close(handle)
    }

    @Test("(d) each ablation preset sets exactly one signal:* key at 0")
    func ablationPresetsSetOneSignalKey() throws {
        let expected: [(String, String)] = [
            ("no_locus", RecallShape.SignalKey.locus),
            ("no_field_fit", RecallShape.SignalKey.fieldFit),
            ("no_matrix", RecallShape.SignalKey.matrix),
            ("no_graph", RecallShape.SignalKey.graph),
            ("no_preference", RecallShape.SignalKey.preference),
            ("no_agreement", RecallShape.SignalKey.agreement),
            ("no_bm25", RecallShape.SignalKey.bm25),
            ("no_vector", RecallShape.SignalKey.vector),
        ]
        for (name, key) in expected {
            let s = try #require(RecallShape.preset(name), "preset \(name) must resolve")
            #expect(s.laneWeights == [key: 0.0], "preset \(name) must exclude exactly \(key)")
            #expect(RecallShape.presetNames.contains(name))
            #expect(!RecallShape.presetDescription(name).isEmpty)
        }
    }
}
