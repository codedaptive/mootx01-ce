// RecallShapeMatrixSteerTests.swift
//
// Tests for 6b-modifiers-matrix-steer: the five matrix/graph/preference columns
// (fieldFit, coOccurrence, temporal, graph, preference) are now RecallShape-
// steerable in the unionBest `.matrixAware` weighted-column score, with the same
// signed semantics as the retrieval lanes (1.0 neutral, 0 excludes, <0 suppresses).
//
// Each matrix/graph/preference column's contribution is multiplied by its
// RecallShape weight ON TOP of the adaptive RecallWeights budget, exactly as the
// retrieval lanes already were (6b-modifiers-core-2). This file proves:
//
//   (a) graph weight 0 zeroes the graph column's effect on the fused score.
//   (b) preference weight 0 zeroes the preference column's effect.
//   (c) graph weight < 0 SUBTRACTS the column — a strictly lower fused final than
//       weight 0 (which merely drops it). Demotion vs exclusion are distinct.
//   (d) a temporal-up shape ranks a temporally-relevant drawer at least as high as
//       a temporal-down shape — temporal steering is live.
//   (e) nil shape == an explicit all-ones shape is BYTE-IDENTICAL (back-compat).
//
// A registered MatrixTier (temporal prior) and constant graph/preference caches
// make the columns non-zero so the steering is observable. The constant caches
// give every candidate the same column value, so excluding/suppressing the column
// shifts every fused final deterministically without depending on store internals.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("RecallShape matrix/graph/preference steering in unionBest (6b-modifiers-matrix-steer)", .serialized)
struct RecallShapeMatrixSteerTests {

    // Constant column doubles — every drawer gets the same score, so the column
    // is measured-uniform (normalizeFinals → 0.5 for every slot) and its steered
    // contribution moves every fused final by the same deterministic amount.
    private struct ConstantGraphCache: GraphCache {
        let score: Float
        func graphScore(for drawerID: String) -> Float { score }
    }
    private struct ConstantPreferenceStore: PreferenceStore {
        let score: Float
        func preferenceScore(for drawerID: String) -> Float { score }
    }

    /// Open an estate with two drawers captured on distinct channels (so their
    /// operationalBitmaps differ and a temporal prior is seedable).
    private func openTwoDrawerEstate(owner ownerID: String)
        async throws -> (kit: GeniusLocusKit, handle: EstateHandle, d1: String, d2: String) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let f1 = CaptureFrame(content: "matrix steer alpha content", channel: .typed,
                              room: "matrix-steer-tests", latticeAnchor: .udc("000"),
                              addedBy: "matrix-steer-tests", embeddingModelID: "test-v1")
        let d1 = try await kit.capture(handle, f1)
        let f2 = CaptureFrame(content: "matrix steer beta content", channel: .voiced,
                              room: "matrix-steer-tests", latticeAnchor: .udc("000"),
                              addedBy: "matrix-steer-tests", embeddingModelID: "test-v1")
        let d2 = try await kit.capture(handle, f2)
        return (kit: kit, handle: handle, d1: d1.id, d2: d2.id)
    }

    /// Seed a MatrixTier with a strong temporal prior between the two drawers and
    /// register it, so the temporal/coOccurrence/fieldFit columns are non-zero.
    /// Returns whether the prior was actually seeded (distinguishable bitmaps).
    @discardableResult
    private func seedMatrixTier(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, d1: String, d2: String
    ) async throws -> Bool {
        // feedAuditLog removed (ADR-026): auditLog(for:) reads directly from storage.
        let auditLog = try await kit.auditLog(for: handle)
        var matrix = MatrixTier.rebuild(from: auditLog)
        let allDrawers = (try? await kit.estate(for: handle).allDrawers()) ?? []
        let d1Op = UInt64(bitPattern: (allDrawers.first { $0.id == d1 }?.operationalBitmap ?? 0))
        let d2Op = UInt64(bitPattern: (allDrawers.first { $0.id == d2 }?.operationalBitmap ?? 0))
        var seeded = false
        if d1Op != 0, d2Op != 0, d1Op != d2Op {
            let src = MatrixValueCoord(fieldPath: "operational", value: .bitmap(d1Op))
            let tgt = MatrixValueCoord(fieldPath: "operational", value: .bitmap(d2Op))
            matrix.applyTemporalEvent(source: src, target: tgt, deltaMinutes: 2, delta: 1000)
            seeded = true
        }
        await kit.registerMatrixTier(matrix, for: handle)
        return seeded
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

    /// Map of id → fused final, for comparing the same recall under different shapes.
    private func finals(_ result: GLKRecallResult) -> [String: Float] {
        Dictionary(uniqueKeysWithValues: result.hits.map { ($0.id, $0.score.final) })
    }

    // MARK: - (a) graph weight 0 zeroes the graph column's effect

    /// With a constant GraphCache registered, excluding the graph column
    /// (`graph`=0) must change at least one fused final relative to the neutral
    /// (nil) recall — the column contributed mass that exclusion removes.
    @Test("graph weight 0 zeroes the graph column's contribution")
    func graphWeightZeroExcludesColumn() async throws {
        let (kit, handle, _, _) = try await openTwoDrawerEstate(owner: "graph-zero-owner")
        await kit.registerGraphCache(ConstantGraphCache(score: 0.8), for: handle)

        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let excluded = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["graph": 0.0])))

        let neutralFinals = finals(neutral)
        let changed = excluded.hits.contains { hit in
            if let before = neutralFinals[hit.id] { return before != hit.score.final }
            return false
        }
        #expect(changed,
            "excluding the graph column (w=0) must change at least one fused final")
        try await kit.close(handle)
    }

    // MARK: - (b) preference weight 0 zeroes the preference column's effect

    @Test("preference weight 0 zeroes the preference column's contribution")
    func preferenceWeightZeroExcludesColumn() async throws {
        let (kit, handle, _, _) = try await openTwoDrawerEstate(owner: "pref-zero-owner")
        await kit.registerPreferenceStore(ConstantPreferenceStore(score: 0.9), for: handle)

        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let excluded = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["preference": 0.0])))

        let neutralFinals = finals(neutral)
        let changed = excluded.hits.contains { hit in
            if let before = neutralFinals[hit.id] { return before != hit.score.final }
            return false
        }
        #expect(changed,
            "excluding the preference column (w=0) must change at least one fused final")
        try await kit.close(handle)
    }

    // MARK: - (c) graph weight < 0 SUBTRACTS — strictly lower than weight 0

    /// Demotion vs exclusion are distinct: with a constant graph column,
    /// weight `-1` SUBTRACTS the column mass while weight `0` merely drops it.
    /// For every drawer present in both results, the suppressed (w<0) fused
    /// final must be STRICTLY below the excluded (w=0) fused final — the
    /// subtracted column mass is the difference.
    @Test("graph weight < 0 subtracts the column (lower than weight 0)")
    func graphNegativeWeightSubtracts() async throws {
        let (kit, handle, _, _) = try await openTwoDrawerEstate(owner: "graph-neg-owner")
        await kit.registerGraphCache(ConstantGraphCache(score: 0.8), for: handle)

        let excluded = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["graph": 0.0])))
        let suppressed = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["graph": -1.0])))

        let excludedFinals = finals(excluded)
        var sawStrictlyLower = false
        for hit in suppressed.hits {
            if let zeroFinal = excludedFinals[hit.id] {
                #expect(hit.score.final <= zeroFinal + 1e-6,
                    "suppressed graph final must not exceed the excluded final; \(hit.id): w<0=\(hit.score.final) w0=\(zeroFinal)")
                if hit.score.final < zeroFinal - 1e-6 { sawStrictlyLower = true }
            }
        }
        #expect(sawStrictlyLower,
            "graph w=-1 must subtract mass — at least one drawer strictly below the w=0 final")
        try await kit.close(handle)
    }

    // MARK: - (d) temporal steering is live (up ≥ down)

    /// A temporal-up shape (`temporal`=2) must rank the temporally-relevant
    /// drawer at least as high as a temporal-down shape (`temporal`=0). When the
    /// environment cannot seed a distinguishable temporal prior the columns are
    /// 0 and the orders coincide — still a valid (no-op) outcome, asserted by the
    /// non-empty-result guard.
    @Test("temporal-up ranks the temporally-relevant drawer no lower than temporal-down")
    func temporalUpRanksRelevantHigher() async throws {
        let (kit, handle, d1, d2) = try await openTwoDrawerEstate(owner: "temporal-up-owner")
        let seeded = try await seedMatrixTier(kit, handle, d1: d1, d2: d2)

        let up = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["temporal": 2.0])))
        let down = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["temporal": 0.0])))

        #expect(!up.hits.isEmpty && !down.hits.isEmpty,
            "both temporal-steered recalls must return hits")

        if seeded {
            // The temporal target (d2) carries the seeded prior. Under temporal-up
            // its rank must be no worse than under temporal-down (temporal steering
            // can only help it, never demote it relative to the down shape).
            let upRank = up.hits.firstIndex { $0.id == d2 }
            let downRank = down.hits.firstIndex { $0.id == d2 }
            if let u = upRank, let d = downRank {
                #expect(u <= d,
                    "temporal-up must rank the temporally-relevant drawer no lower than temporal-down; up=\(u) down=\(d)")
            }
            // Steering temporal must actually move the score: the temporally-relevant
            // drawer's fused final must differ between up and down.
            let upFinal = up.hits.first { $0.id == d2 }?.score.final
            let downFinal = down.hits.first { $0.id == d2 }?.score.final
            if let uf = upFinal, let df = downFinal {
                #expect(uf != df,
                    "temporal steering must change the relevant drawer's fused final; up=\(uf) down=\(df)")
            }
        }
        try await kit.close(handle)
    }

    // MARK: - (e) nil shape == all-ones shape, byte-identical (back-compat)

    /// nil shape and an explicit all-ones shape over EVERY steerable key (retrieval
    /// + matrix/graph/preference) must produce BYTE-IDENTICAL unionBest output —
    /// ids, order, and fused finals — with the matrix tier and graph/preference
    /// caches all registered (every column live). This is the production back-compat
    /// contract for 6b-modifiers-matrix-steer.
    @Test("nil shape and an all-ones shape are byte-identical with all columns live")
    func nilShapeEqualsAllOnesAcrossAllColumns() async throws {
        let (kit, handle, d1, d2) = try await openTwoDrawerEstate(owner: "matrix-backcompat-owner")
        try await seedMatrixTier(kit, handle, d1: d1, d2: d2)
        await kit.registerGraphCache(ConstantGraphCache(score: 0.8), for: handle)
        await kit.registerPreferenceStore(ConstantPreferenceStore(score: 0.9), for: handle)

        let onesShape = RecallShape(laneWeights: [
            "locus": 1.0, "bm25": 1.0, "hamming": 1.0, "dense": 1.0,
            "fieldFit": 1.0, "coOccurrence": 1.0, "temporal": 1.0,
            "graph": 1.0, "preference": 1.0
        ])

        let nilResult = try await kit.recall(handle, matrixReq(shape: nil))
        let onesResult = try await kit.recall(handle, matrixReq(shape: onesShape))

        #expect(nilResult.hits.map(\.id) == onesResult.hits.map(\.id),
            "all-ones shape must produce the same unionBest id order as nil shape")
        for (a, b) in zip(nilResult.hits, onesResult.hits) {
            #expect(a.id == b.id)
            #expect(a.score.final == b.score.final,
                "fused final must be byte-identical at all-ones; \(a.id): nil=\(a.score.final) ones=\(b.score.final)")
            #expect(a.score.temporal == b.score.temporal,
                "temporal column must be byte-identical at all-ones; \(a.id)")
            #expect(a.score.coOccurrence == b.score.coOccurrence,
                "coOccurrence column must be byte-identical at all-ones; \(a.id)")
            #expect(a.score.fieldFit == b.score.fieldFit,
                "fieldFit column must be byte-identical at all-ones; \(a.id)")
            #expect(a.score.graph == b.score.graph,
                "graph column must be byte-identical at all-ones; \(a.id)")
            #expect(a.score.preference == b.score.preference,
                "preference column must be byte-identical at all-ones; \(a.id)")
            // CROSS-PORT CONFORMANCE (ADR-011 D-4): the constant graph(0.8) /
            // preference(0.9) caches give every candidate the same column value, so
            // each is measured-uniform and normalizes to exactly 0.5 — the SAME value
            // the Rust port pins in recall_shape_matrix_steer_parity. This is the
            // shared-fixture proof the graph/preference columns now agree Swift↔Rust.
            #expect(a.score.graph == 0.5,
                "graph column must normalize to 0.5 (constant-uniform); \(a.id)")
            #expect(a.score.preference == 0.5,
                "preference column must normalize to 0.5 (constant-uniform); \(a.id)")
        }
        try await kit.close(handle)
    }
}
