// FloatLaneStoreTests.swift
//
// Lane D (in-house float lane) tests at the VectorStore boundary:
//   • embedFloat on the EmbeddingProvider (override + default opt-out)
//   • float vector round-trip through the store (write → findNearestFloat)
//   • findNearestFloat exactness vs a hand-computed small case
//   • resident float reload after reopen (process-restart simulation)
//   • the deterministic cross-language rank-identity fixture
//
// All tests use the REAL on-disk SQLite backend (makeScratchStorage) so the
// float rows survive the same primitive-type round-trip production uses.
//
// Float determinism note (arch spec §6): the float lane is reproducible
// within one build/config but NOT four-way bit-identical. These tests assert
// RANK order (which item ranks where), never bit-identical cosine values.
// The shared rank fixture below is the Swift half of the Swift-vs-Rust
// rank-identity gate; the Rust half lives in rust/tests/float_lane_tests.rs.

import Testing
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import Foundation
@testable import VectorKit

// MARK: - Shared cross-language rank fixture

/// The deterministic fixture both languages score. Five 4-d vectors plus a
/// probe; cosine ranking is unambiguous (no ties) so Swift and Rust MUST
/// produce the identical item-ID order. Keep BYTE-FOR-BYTE in sync with the
/// Rust `RANK_FIXTURE` in rust/tests/float_lane_tests.rs.
///
/// Probe = [1, 1, 0, 0] (unit direction along the x=y diagonal of the first
/// two axes). Expected cosine-nearest order, computed by hand:
///   v_ab = [2, 2, 0, 0]  → same direction as probe        → cos 1.000 (nearest)
///   v_a  = [1, 0, 0, 0]  → 45° off probe                  → cos 0.707
///   v_ad = [3, 0, 0, 1]  → mostly x, small w              → cos 0.671
///   v_d  = [0, 0, 0, 5]  → orthogonal to probe            → cos 0.000
///   v_neg= [-1,-1, 0, 0] → opposite direction             → cos -1.000 (farthest)
/// → rank order: ab, a, ad, d, neg
enum FloatRankFixture {
    static let modelID = "rank-model"
    static let modelVersion = "1"
    static let probe: [Float] = [1, 1, 0, 0]
    static let expectedOrder = ["v_ab", "v_a", "v_ad", "v_d", "v_neg"]
    /// FARTHEST (anti-similarity) order — the most DISSIMILAR first. Distances
    /// are all distinct (no ties), so this is the exact reverse of
    /// `expectedOrder`: v_neg (cos −1) → … → v_ab (cos 1). Both languages MUST
    /// produce this identical order via `findFarthestFloat`. Keep in sync with
    /// the Rust `RANK_FIXTURE` farthest expectation.
    static let expectedFarthestOrder = ["v_neg", "v_d", "v_ad", "v_a", "v_ab"]
    static let vectors: [(String, [Float])] = [
        ("v_a",   [1, 0, 0, 0]),
        ("v_ab",  [2, 2, 0, 0]),
        ("v_ad",  [3, 0, 0, 1]),
        ("v_d",   [0, 0, 0, 5]),
        ("v_neg", [-1, -1, 0, 0]),
    ]
}

@Suite("FloatLaneStore", .serialized)
struct FloatLaneStoreTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() async throws -> VectorStore {
        let storage = try makeScratchStorage()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage)
    }

    // MARK: - embedFloat

    @Test("embedFloat returns the pooled vector the provider was given")
    func embedFloatReturnsPooledVector() async throws {
        let pooled: [Float] = [0.25, -0.5, 0.75, 1.0]
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "p", modelVersion: "1", projectionSeed: 7,
            inference: { _ in pooled }
        )
        let out = try await provider.embedFloat("hello")
        #expect(out == pooled)
    }

    @Test("embedFloat returns empty for empty input (no dense direction)")
    func embedFloatEmptyInputReturnsEmpty() async throws {
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "p", modelVersion: "1", projectionSeed: 7,
            inference: { _ in [1, 2, 3] }
        )
        let out = try await provider.embedFloat("")
        #expect(out.isEmpty)
    }

    @Test("embedFloat default opt-out throws embeddingFailed")
    func embedFloatDefaultThrows() async throws {
        // A provider that does NOT override embedFloat falls through to the
        // protocol default, which throws — the float lane is opt-in.
        struct BinaryOnlyProvider: EmbeddingProvider {
            let modelID = "binary-only"
            let modelVersion = "1"
            func embed(_ text: String) async throws -> Engram { Engram.zero }
        }
        let provider = BinaryOnlyProvider()
        await #expect(throws: VectorKitError.self) {
            _ = try await provider.embedFloat("anything")
        }
    }

    // MARK: - Round-trip + exactness

    @Test("float vector round-trips through the store and ranks by cosine")
    func floatRoundTripThroughStore() async throws {
      // addPayload emits telemetry via the Intellectus global singleton;
      // hold GlobalTestLock so a concurrent telemetry test's exact-count
      // assertions are not corrupted by this suite's writes.
      try await GlobalTestLock.shared.withLock {
        let store = try await makeStore()
        // Two clearly-separated directions plus the probe's own direction.
        try await store.addPayload(
            itemID: "near", vectorIndex: 0,
            payload: VectorPayload(floats: [1, 0, 0]),
            modelID: "m", modelVersion: "1", filedAt: Self.now)
        try await store.addPayload(
            itemID: "far", vectorIndex: 0,
            payload: VectorPayload(floats: [0, 1, 0]),
            modelID: "m", modelVersion: "1", filedAt: Self.now)

        let matches = try await store.findNearestFloat(
            probe: [1, 0, 0], modelID: "m", limit: 2)
        #expect(matches.count == 2)
        #expect(matches[0].itemID == "near")   // cosine distance ~0
        #expect(matches[1].itemID == "far")    // orthogonal, cosine distance ~1
        // Exactness: the nearest is an exact direction match → distance ~0;
        // the orthogonal vector → cosine distance 1.0 → ×10_000 ≈ 10000.
        #expect(matches[0].distance == 0)
        #expect(matches[1].distance == 10_000)
      }
    }

    @Test("findNearestFloat exactness vs a hand-computed three-vector case")
    func findNearestFloatHandComputed() async throws {
      try await GlobalTestLock.shared.withLock {
        let store = try await makeStore()
        // Probe [3,4,0]: ‖probe‖ = 5.
        //   a=[3,4,0]   identical direction        → cos 1.000 → dist 0
        //   b=[4,3,0]   cos = (12+12)/(5·5)=24/25=0.96 → dist 0.04 → ×1e4 = 400
        //   c=[0,0,1]   orthogonal                 → cos 0.000 → dist 1.0 → 10000
        for (id, v) in [("a", [Float(3),4,0]), ("b", [4,3,0]), ("c", [0,0,1])] {
            try await store.addPayload(
                itemID: id, vectorIndex: 0,
                payload: VectorPayload(floats: v),
                modelID: "m", modelVersion: "1", filedAt: Self.now)
        }
        let matches = try await store.findNearestFloat(
            probe: [3, 4, 0], modelID: "m", limit: 3)
        #expect(matches.map(\.itemID) == ["a", "b", "c"])
        #expect(matches[0].distance == 0)
        #expect(matches[1].distance == 400)
        #expect(matches[2].distance == 10_000)
      }
    }

    @Test("findNearestFloat restricts to the queried model partition")
    func findNearestFloatModelScoped() async throws {
      try await GlobalTestLock.shared.withLock {
        let store = try await makeStore()
        try await store.addPayload(
            itemID: "in", vectorIndex: 0,
            payload: VectorPayload(floats: [1, 0]),
            modelID: "model-a", modelVersion: "1", filedAt: Self.now)
        try await store.addPayload(
            itemID: "out", vectorIndex: 0,
            payload: VectorPayload(floats: [1, 0]),   // same vector, other model
            modelID: "model-b", modelVersion: "1", filedAt: Self.now)
        let matches = try await store.findNearestFloat(
            probe: [1, 0], modelID: "model-a", limit: 5)
        #expect(matches.count == 1)
        #expect(matches[0].itemID == "in")
      }
    }

    // MARK: - Reload after reopen

    @Test("resident float index rebuilds after store reopen (process restart)")
    func floatIndexSurvivesReopenSQLite() async throws {
      try await GlobalTestLock.shared.withLock {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorkit-float-reopen-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        // Session 1: write float rows, then drop the store.
        do {
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)
            try await store.addPayload(
                itemID: "near", vectorIndex: 0,
                payload: VectorPayload(floats: [1, 0, 0]),
                modelID: "m", modelVersion: "1", filedAt: Self.now)
            try await store.addPayload(
                itemID: "far", vectorIndex: 0,
                payload: VectorPayload(floats: [0, 0, 1]),
                modelID: "m", modelVersion: "1", filedAt: Self.now)
        }

        // Session 2: a brand-new store on the same file rebuilds the float
        // index from the table (the source of truth) on first search.
        let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await storage2.open(schema: VectorStore.schemaDeclaration)
        let store2 = VectorStore(storage: storage2)
        let matches = try await store2.findNearestFloat(
            probe: [1, 0, 0], modelID: "m", limit: 2)
        #expect(matches.count == 2)
        #expect(matches[0].itemID == "near")
        #expect(matches[1].itemID == "far")
      }
    }

    // MARK: - Cross-language rank fixture (Swift half)

    @Test("rank-identity fixture: Swift produces the canonical cosine order")
    func rankFixtureSwiftOrder() async throws {
      try await GlobalTestLock.shared.withLock {
        let store = try await makeStore()
        for (id, v) in FloatRankFixture.vectors {
            try await store.addPayload(
                itemID: id, vectorIndex: 0,
                payload: VectorPayload(floats: v),
                modelID: FloatRankFixture.modelID,
                modelVersion: FloatRankFixture.modelVersion,
                filedAt: Self.now)
        }
        let matches = try await store.findNearestFloat(
            probe: FloatRankFixture.probe,
            modelID: FloatRankFixture.modelID,
            limit: FloatRankFixture.vectors.count)
        #expect(matches.map(\.itemID) == FloatRankFixture.expectedOrder)
      }
    }

    @Test("farthest rank-identity fixture: Swift produces the canonical anti-similarity order")
    func farthestRankFixtureSwiftOrder() async throws {
      try await GlobalTestLock.shared.withLock {
        let store = try await makeStore()
        for (id, v) in FloatRankFixture.vectors {
            try await store.addPayload(
                itemID: id, vectorIndex: 0,
                payload: VectorPayload(floats: v),
                modelID: FloatRankFixture.modelID,
                modelVersion: FloatRankFixture.modelVersion,
                filedAt: Self.now)
        }
        // findFarthestFloat surfaces the most DISSIMILAR rows first. The
        // canonical order is the reverse of the nearest fixture (no ties).
        let matches = try await store.findFarthestFloat(
            probe: FloatRankFixture.probe,
            modelID: FloatRankFixture.modelID,
            limit: FloatRankFixture.vectors.count)
        #expect(matches.map(\.itemID) == FloatRankFixture.expectedFarthestOrder)
      }
    }
}
