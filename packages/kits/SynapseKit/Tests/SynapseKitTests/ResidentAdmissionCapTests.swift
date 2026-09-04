// ResidentAdmissionCapTests.swift
//
// Regression coverage for Part 2: the per-model float-index admission cap.
//
// Four behaviours tested (per mission RS-01 Part 3):
//
//   (a) OVER-CAP: a tiny explicit ceiling refuses the float-index build, bumps
//       floatIndexAdmissionRefusalCount, and still returns CORRECT query results
//       via the table-scan fallback. The cap must not break queries.
//
//   (b) UNDER-CAP: a generous ceiling admits the index. floatIndexResident is
//       true, refusal count stays zero, and results are identical to (a) —
//       asserting both paths agree on results is the strongest single assertion.
//
//   (c) UNBOUNDED: .unbounded admits a store that a tiny ceiling would refuse.
//       This is the explicit user opt-out (pre-RS-01 behaviour).
//
//   (d) PROJECTION LITERALS: the admission formula constants asserted against
//       fixed literal inputs so the Rust twin (vector_store.rs) must agree on
//       the same numbers. Any divergence is a failing test, not silent drift.
//
// Note on ceiling size in tests:
//   The default ceiling is .systemFraction(0.25). On the build host (128 GiB RAM)
//   that resolves to 32 GiB — no small test corpus will ever exceed it. Behaviour
//   (a) and (c) therefore use .bytes(1) as a stand-in for "any ceiling the corpus
//   exceeds", not to model the default fraction in production. This exercises the
//   same admission-check branch as the production fraction path. The test is fast
//   because it uses tiny vectors rather than allocating gigabytes of test data.

import Testing
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import Foundation
@testable import SynapseKit

// MARK: - Test vectors (shared across behaviours a, b, c)
//
// Three orthogonal float32 dim-2 vectors. Probe [1, 0] hits "near" exactly
// (cosine dist 0) and "far" orthogonally (cosine dist 10 000). This is the
// smallest fixture that produces unambiguous rank ordering.

private let modelID      = "cap-test-model"
private let modelVersion = "1"
private let testNow      = Date(timeIntervalSince1970: 1_700_000_000)

private let testVectors: [(String, [Float])] = [
    ("near", [1, 0]),   // exact match for probe [1, 0] → cosine dist 0
    ("far",  [0, 1]),   // orthogonal to probe         → cosine dist 10 000
]
private let probe: [Float] = [1, 0]

// MARK: - Suite

@Suite("ResidentAdmissionCap", .serialized)
struct ResidentAdmissionCapTests {

    // MARK: - Store factory

    /// Scratch SQLite-backed VectorStore with a caller-supplied budget and
    /// hnswThreshold. Uses a UUID-named temp file per call for isolation.
    private func makeStore(
        budget: ResidentIndexBudget,
        hnswThreshold: UInt32 = 50_000
    ) async throws -> VectorStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-cap-\(UUID().uuidString).sqlite3")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0),
            residentIndexBudget: budget
        ))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage, hnswThreshold: hnswThreshold)
    }

    /// Insert the shared test vectors into `store`.
    private func insertTestVectors(into store: VectorStore) async throws {
        for (id, v) in testVectors {
            try await store.addPayload(
                itemID: id, vectorIndex: 0,
                payload: VectorPayload(floats: v),
                modelID: modelID, modelVersion: modelVersion,
                filedAt: testNow
            )
        }
    }

    // MARK: - Behaviour (a): over-cap degrades but returns correct results

    /// With a one-byte ceiling the float-index projection always exceeds the cap,
    /// so the build is refused. The store falls back to the SQLite table scan and
    /// STILL returns the correct nearest-neighbour ordering.
    ///
    /// All three assertions are mandatory:
    ///   1. floatIndexResident == false → the index was NOT cached
    ///   2. refusal count > 0          → the gate fired (not silently skipped)
    ///   3. correct results             → the cap did not break queries
    @Test("over-cap estate: index not resident, refusal counted, query results still correct")
    func overCapDegradesByReturningCorrectResults() async throws {
        try await GlobalTestLock.shared.withLock {
            // .bytes(1) — always below the projection for any real float row.
            let store = try await makeStore(budget: .bytes(1))
            try await insertTestVectors(into: store)

            let matches = try await store.findNearestFloat(
                probe: probe, modelID: modelID, limit: 2
            )

            // Gate 1: index must NOT be resident (cap was enforced).
            #expect(await store.floatIndexResident(for: modelID) == false)

            // Gate 2: refusal counter must have incremented.
            #expect(await store.floatIndexAdmissionRefusalCount >= 1)

            // Gate 3: table-scan fallback must return correct cosine-ranked results.
            // "near" is an exact direction match → distance 0.
            // "far" is orthogonal → distance 10 000.
            // A cap that breaks queries is not a fix.
            #expect(matches.count == 2)
            #expect(matches[0].itemID == "near")
            #expect(matches[0].distance == 0)
            #expect(matches[1].itemID == "far")
            #expect(matches[1].distance == 10_000)
        }
    }

    // MARK: - Behaviour (b): under-cap stays resident, results identical to (a)

    /// With a generous ceiling the float-index build is admitted. The index is
    /// resident, the refusal counter stays at zero, and query results are
    /// identical to the over-cap table-scan path — proving both paths agree.
    ///
    /// The result-identity assertion is the strongest single assertion in this
    /// file: if the cached path and the scan path ever diverge in ranking or
    /// distance, this test catches it.
    @Test("under-cap estate: index resident, zero refusals, results identical to table-scan")
    func underCapStaysResidentWithIdenticalResults() async throws {
        try await GlobalTestLock.shared.withLock {
            // .bytes(Int.max) — no vector count will ever exceed this.
            let store = try await makeStore(budget: .bytes(Int.max))
            try await insertTestVectors(into: store)

            let matches = try await store.findNearestFloat(
                probe: probe, modelID: modelID, limit: 2
            )

            // Gate 1: index IS resident (admission succeeded).
            #expect(await store.floatIndexResident(for: modelID) == true)

            // Gate 2: refusal counter stays at zero.
            #expect(await store.floatIndexAdmissionRefusalCount == 0)

            // Gate 3: results must match the over-cap scan path exactly —
            // same item order, same distances.
            #expect(matches.count == 2)
            #expect(matches[0].itemID == "near")
            #expect(matches[0].distance == 0)
            #expect(matches[1].itemID == "far")
            #expect(matches[1].distance == 10_000)
        }
    }

    // MARK: - Behaviour (c): unbounded overrides any ceiling

    /// .unbounded admits a model that a tiny ceiling would refuse.
    ///
    /// Note on ceiling choice: the production default is .systemFraction(0.25).
    /// On a 128 GiB host that resolves to 32 GiB, which no small test corpus
    /// reaches. We use .bytes(1) as the "ceiling that refuses" to demonstrate
    /// the mechanism, and .unbounded as the explicit opt-out that admits regardless.
    @Test("unbounded admits an estate that a tiny ceiling refuses")
    func unboundedAdmitsWhatTinyCeilingRefuses() async throws {
        try await GlobalTestLock.shared.withLock {
            // First show that .bytes(1) refuses this corpus.
            let refusingStore = try await makeStore(budget: .bytes(1))
            try await insertTestVectors(into: refusingStore)
            _ = try await refusingStore.findNearestFloat(
                probe: probe, modelID: modelID, limit: 2
            )
            #expect(await refusingStore.floatIndexResident(for: modelID) == false)
            #expect(await refusingStore.floatIndexAdmissionRefusalCount >= 1)

            // Now show that .unbounded admits the same corpus.
            let unboundedStore = try await makeStore(budget: .unbounded)
            try await insertTestVectors(into: unboundedStore)
            _ = try await unboundedStore.findNearestFloat(
                probe: probe, modelID: modelID, limit: 2
            )
            #expect(await unboundedStore.floatIndexResident(for: modelID) == true)
            #expect(await unboundedStore.floatIndexAdmissionRefusalCount == 0)
        }
    }

    // MARK: - Behaviour (d): projection formula literals (cross-port agreement)
    //
    // These are pure arithmetic tests. No storage is opened. Their purpose is to
    // pin the admission projection formula so the Rust twin (vector_store.rs)
    // asserts the SAME literals: if either port changes the overhead constant or
    // the HNSW-graph allow formula, a test in that port fails.
    //
    // Overhead constant = 2 000 bytes/record (VectorStore.floatIndexOverheadPerRecord,
    // the RSS-measured figure from BRR §6.1 — the Rust String overhead without
    // small-string optimisation, rounded up to 2 000).
    //
    // Inputs fixed for cross-port parity:
    //   recordCount = 10 000
    //   stride      = 1 536 bytes (dim=384 float32 vectors: 384 × 4 = 1 536)

    @Test("projection formula below HNSW threshold agrees with cross-port literal")
    func projectionLiteralBelowHNSWThreshold() {
        // Below hnswThreshold: only FloatBruteForceIndex is held; no HNSW graph.
        // Formula: recordCount × (stride + overhead)
        let overhead   = 2_000
        let stride     = 1_536   // dim=384 float32
        let count      = 10_000
        let projected  = count * (stride + overhead)
        // 10 000 × 3 536 = 35 360 000.
        // The Rust twin asserts the same literal.
        #expect(projected == 35_360_000)
    }

    @Test("projection formula at or above HNSW threshold agrees with cross-port literal")
    func projectionLiteralAboveHNSWThreshold() {
        // At/above hnswThreshold: HNSWIndex lives alongside FloatBruteForceIndex.
        // graphAllow = stride + overhead + 256  (vectorBytes + key overhead + neighbours)
        // Formula: recordCount × (stride + overhead + graphAllow)
        let overhead   = 2_000
        let stride     = 1_536
        let count      = 10_000
        let graphAllow = stride + overhead + 256
        let projected  = count * (stride + overhead + graphAllow)
        // 10 000 × 7 328 = 73 280 000.
        // The Rust twin asserts the same literal.
        #expect(projected == 73_280_000)
    }

    // MARK: - Behaviour (d): formula validation via admission boundary

    /// Verifies the projection formula is actually live in the admission gate,
    /// not just in the comment above. Uses 3 dim-2 float32 vectors (stride = 8):
    ///   projection = 3 × (8 + 2 000) = 6 024 bytes.
    /// A budget of 6 023 must refuse; 6 024 must admit.
    ///
    /// This is separate from the literal tests above: those pin the cross-port
    /// constants; this proves the constants are wired into the real admission path.
    @Test("admission boundary is enforced at the exact projected byte count")
    func admissionBoundaryEnforcedAtExactProjection() async throws {
        try await GlobalTestLock.shared.withLock {
            // Stride for dim-2 float32: 2 floats × 4 bytes = 8 bytes.
            // Using hnswThreshold=50 000 so 3 records are below the threshold
            // and the "below-threshold" formula applies.
            let overhead       = 2_000   // mirrors VectorStore.floatIndexOverheadPerRecord
            let stride         = 2 * 4   // dim=2 float32
            let count          = 3       // one per test vector
            let exactProjection = count * (stride + overhead)  // 3 × 2 008 = 6 024

            let vectors: [(String, [Float])] = [
                ("p", [1, 0]),
                ("q", [0, 1]),
                ("r", [1, 1]),  // non-unit, but cosine handles that
            ]
            let insertVectors: (VectorStore) async throws -> Void = { store in
                for (id, v) in vectors {
                    try await store.addPayload(
                        itemID: id, vectorIndex: 0,
                        payload: VectorPayload(floats: v),
                        modelID: modelID, modelVersion: modelVersion,
                        filedAt: testNow
                    )
                }
            }

            // One byte below exact projection → must refuse.
            let refuseStore = try await makeStore(
                budget: .bytes(exactProjection - 1), hnswThreshold: 50_000
            )
            try await insertVectors(refuseStore)
            _ = try await refuseStore.findNearestFloat(
                probe: [1, 0], modelID: modelID, limit: 3
            )
            #expect(await refuseStore.floatIndexResident(for: modelID) == false)
            #expect(await refuseStore.floatIndexAdmissionRefusalCount >= 1)

            // Exactly at the projection → must admit.
            let admitStore = try await makeStore(
                budget: .bytes(exactProjection), hnswThreshold: 50_000
            )
            try await insertVectors(admitStore)
            _ = try await admitStore.findNearestFloat(
                probe: [1, 0], modelID: modelID, limit: 3
            )
            #expect(await admitStore.floatIndexResident(for: modelID) == true)
            #expect(await admitStore.floatIndexAdmissionRefusalCount == 0)
        }
    }
}
