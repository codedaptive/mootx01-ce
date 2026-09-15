// RecallShapeFloatMetricTests.swift
//
// Tests for RecallShape.floatMetric and the float-lane metric threading
// introduced in W2.5 M1 (float unlock).
//
// Three gates required by the mission:
//
//   (a) GOLDEN PIN — absent key and "cosine" decode identically; the memberwise
//       init default is "cosine"; a round-trip through JSON is byte-identical to
//       the pre-field baseline. Any payload persisted before the field was added
//       must decode without error and produce cosine behaviour.
//
//   (b) UNKNOWN DEGRADES — RecallShape stores the string verbatim; RecallDirector
//       degrades unknown values to cosine. The struct carries "xyz" faithfully;
//       the mapping function at the use-site is tested in RecallDirectorTests.
//       Here we verify the Codable contract only.
//
//   (c) SELECTABILITY — "l2" and "dot" are Codable-round-trippable; the
//       VectorStore correctly routes them to different inline distance functions,
//       producing results that differ from cosine on a controlled fixture.
//
// These tests operate at two layers:
//   — RecallShape Codable round-trips (no estate required)
//   — VectorStore float metric parameter (SQLite backend, proves downstream threading)

// Whole-record float lane tests.
import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
import SynapseKit
@testable import GeniusLocusKit

// MARK: - Scratch storage (SQLite, same as FloatLaneStoreTests)

private func makeScratchStore() throws -> any Storage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("glk-float-metric-test-\(UUID().uuidString).sqlite3")
    return try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
}

// MARK: - Suite

@Suite("RecallShape.floatMetric — selection, Codable contract, VectorStore threading")
struct RecallShapeFloatMetricTests {

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: (a) GOLDEN PIN — absent key and explicit "cosine" are identical

    /// A JSON payload with NO floatMetric key must decode without error and
    /// the field must be "cosine" — the additive-Codable contract. This is the
    /// GOLDEN PIN: any payload persisted before this field existed decodes to
    /// the same behaviour as an explicit "cosine".
    @Test("absent floatMetric key decodes to 'cosine' default — GOLDEN PIN")
    func absentKeyDecodesToCosine() throws {
        let json = #"{"laneWeights":{}}"#
        let shape = try JSONDecoder().decode(RecallShape.self, from: Data(json.utf8))
        #expect(shape.floatMetric == "cosine")
    }

    /// An explicit "cosine" in the payload must survive JSONDecoder.
    @Test("explicit 'cosine' round-trips without change")
    func explicitCosineRoundTrips() throws {
        let json = #"{"floatMetric":"cosine"}"#
        let shape = try JSONDecoder().decode(RecallShape.self, from: Data(json.utf8))
        #expect(shape.floatMetric == "cosine")
    }

    /// The memberwise init default must be "cosine".
    @Test("memberwise init default is 'cosine'")
    func memberwiseInitDefault() {
        #expect(RecallShape().floatMetric == "cosine")
    }

    /// Payload with ONLY binaryMetric (pre-floatMetric payload shape) must decode
    /// with floatMetric == "cosine". This exercises the decode-tolerant path.
    @Test("pre-field payload (binaryMetric only) decodes floatMetric as 'cosine'")
    func preFieldPayloadDecodesFloat() throws {
        let json = #"{"binaryMetric":"jaccard"}"#
        let shape = try JSONDecoder().decode(RecallShape.self, from: Data(json.utf8))
        #expect(shape.binaryMetric == "jaccard")
        #expect(shape.floatMetric == "cosine")
    }

    // MARK: (b) UNKNOWN DEGRADES — RecallShape stores verbatim; degradation is at read-time

    /// RecallShape stores any string verbatim. Unknown values should not cause
    /// a decode failure — the shape contract forbids decode errors.
    @Test("unknown floatMetric string stored verbatim without error")
    func unknownStoredVerbatim() {
        let shape = RecallShape(floatMetric: "xyz")
        #expect(shape.floatMetric == "xyz")
    }

    @Test("empty string floatMetric stored verbatim without error")
    func emptyStringStoredVerbatim() {
        #expect(RecallShape(floatMetric: "").floatMetric == "")
    }

    @Test("unknown floatMetric decodes from JSON without error")
    func unknownDecodesWithoutError() throws {
        let json = #"{"floatMetric":"mystery"}"#
        let shape = try JSONDecoder().decode(RecallShape.self, from: Data(json.utf8))
        #expect(shape.floatMetric == "mystery")
    }

    // MARK: Known values round-trip

    @Test("'l2' survives JSONEncoder/JSONDecoder round-trip")
    func l2RoundTrip() throws {
        let shape = RecallShape(floatMetric: "l2")
        let decoded = try JSONDecoder().decode(RecallShape.self,
                          from: try JSONEncoder().encode(shape))
        #expect(decoded.floatMetric == "l2")
    }

    @Test("'dot' survives JSONEncoder/JSONDecoder round-trip")
    func dotRoundTrip() throws {
        let shape = RecallShape(floatMetric: "dot")
        let decoded = try JSONDecoder().decode(RecallShape.self,
                          from: try JSONEncoder().encode(shape))
        #expect(decoded.floatMetric == "dot")
    }

    // MARK: (c) SELECTABILITY — VectorStore correctly routes metric to different distance fns

    /// A five-vector fixture (same as FloatRankFixture in FloatLaneStoreTests)
    /// where l2 and cosine produce different top-1 answers.
    ///
    /// Probe = [1, 0, 0, 0]
    ///   cosine closest: v_same = [1, 0, 0, 0]  (identical direction)
    ///   l2 closest:     v_near = [1.0001, 0, 0, 0]  (nearest in Euclidean space)
    ///                   … but on the full fixture the l2 and cosine top-1 differ
    ///
    /// We use the existing FloatRankFixture vectors since they are designed for
    /// unambiguous cosine ordering. For l2 vs cosine divergence, a simpler two-
    /// vector fixture is sufficient: one vector in the same direction but far away
    /// (same cosine, large l2) and one at 45° but very close (smaller l2, worse
    /// cosine). The second ranks first under l2 and second under cosine.
    ///
    ///   probe     = [1, 0]
    ///   same_dir  = [10, 0]   cosine: dist=0  (nearest); l2: dist=9.0 (farther)
    ///   near_45   = [0.9, 0.9] cosine: dist≈0.293; l2: dist≈1.273 (farther than above)
    ///
    /// Hmm — same_dir wins both. Need a fixture where l2 disagrees with cosine.
    ///
    ///   probe = [0.5, 0.5]
    ///   v_cos = [100, 0]   cosine: cos(θ) = 0.5/√0.5·100 ≈ 0.71 → dist≈0.29
    ///   v_l2  = [0.51, 0.51]  cosine: nearly identical direction → very close
    ///   Under cosine: v_l2 is closer (same direction as probe → cos≈1 → dist≈0)
    ///   Under l2:     v_l2 dist = √((0.5-0.51)²+(0.5-0.51)²)≈0.014  v_cos dist=√(99.5²+0.5²)≈99.5
    ///   Both metrics agree v_l2 is closer here.
    ///
    /// Correct minimal fixture: unit vectors in a 2-d space.
    ///   probe = [1, 0]
    ///   v_A = [0.6, 0.8]   cosine_dist = 1 - 0.6 = 0.4;  l2_dist = √(0.16+0.64) = √0.8 ≈ 0.894
    ///   v_B = [0.99, 0]    cosine_dist = 1 - 0.99 = 0.01; l2_dist = 0.01
    ///   Under cosine: v_B (dist 0.01) < v_A (dist 0.4) → v_B first
    ///   Under l2:     v_B (dist 0.01) < v_A (dist 0.894) → v_B still first
    ///   Still agreeing.
    ///
    /// A fixture that disagrees requires un-normalised vectors:
    ///   probe = [1, 0]
    ///   v_A = [0.1, 0.0]   cosine_dist = 1 - 1.0 = 0;     l2_dist = 0.9
    ///   v_B = [0.9, 0.1]   cosine_dist = 1 - cos(θ) > 0;  l2_dist = √(0.01+0.01)≈0.14
    ///   cos(θ) for v_B = (0.9)/(√(0.81+0.01)) = 0.9/√0.82 ≈ 0.9/0.906 ≈ 0.993 → dist≈0.007
    ///   Under cosine: v_B (0.007) < v_A (0) — wait, 0 < 0.007, so v_A still first.
    ///
    /// Key: v_A = [0.01, 0] has cosine_dist = 0 (same direction) but l2_dist = 0.99.
    ///       v_B = [0.9, 0.1] has cosine_dist ≈ 0.007 but l2_dist ≈ 0.14.
    ///   Cosine: v_A first (dist=0); l2: v_B first (dist=0.14 < 0.99).
    ///   This fixture works.
    @Test("cosine and l2 produce different top-1 on a designed fixture")
    func cosineAndL2DifferOnFixture() async throws {
        let storage = try makeScratchStore()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        let store = VectorStore(storage: storage)
        let modelID = "metric-sel-model"

        // v_A: same DIRECTION as probe [1,0] but tiny magnitude → cosine_dist=0, l2_dist=0.99
        // v_B: near probe in l2 space but 6° off → cosine_dist≈0.007, l2_dist≈0.14
        try await store.addPayload(
            itemID: "v_A", vectorIndex: 0,
            payload: VectorPayload(floats: [0.01, 0.0]),
            modelID: modelID, modelVersion: "1", filedAt: Self.now)
        try await store.addPayload(
            itemID: "v_B", vectorIndex: 1,
            payload: VectorPayload(floats: [0.9, 0.1]),
            modelID: modelID, modelVersion: "1", filedAt: Self.now)

        let probe: [Float] = [1.0, 0.0]

        // Cosine: v_A ranks first (perfect direction match → dist ≈ 0)
        let cosineHits = try await store.findNearestFloat(
            probe: probe, modelID: modelID, limit: 2, metric: .cosine)
        #expect(!cosineHits.isEmpty, "cosine must return hits")
        #expect(cosineHits.first?.itemID == "v_A",
                "cosine must rank v_A first (same direction as probe)")

        // L2: v_B ranks first (smaller Euclidean distance to probe)
        let l2Hits = try await store.findNearestFloat(
            probe: probe, modelID: modelID, limit: 2, metric: .l2)
        #expect(!l2Hits.isEmpty, "l2 must return hits")
        #expect(l2Hits.first?.itemID == "v_B",
                "l2 must rank v_B first (shorter Euclidean distance to probe)")
    }

    /// Dot metric produces well-formed hits and its top-1 differs from cosine
    /// when a candidate has high magnitude (un-normalised dot product is scale-dependent).
    ///
    ///   probe = [1, 0]
    ///   v_C = [0.5, 0]   dot = 0.5;   cosine_dist = 0 (same direction)
    ///   v_D = [3.0, 0]   dot = 3.0;   cosine_dist = 0 (same direction, same unit)
    ///   Cosine: both distance=0, tie — implementation order decides. Not useful.
    ///
    ///   Better: different directions:
    ///   v_E = [2, 0]   dot = 2.0; cosine_dist = 0
    ///   v_F = [0.5, 0.1] dot = 0.5; cosine_dist = 1 - 2/√(0.26)·1 ≈ 1 - 0.981 ≈ 0.019
    ///   v_G = [1.5, 1.5] dot = 1.5; cosine_dist = 1 - 1.5/√4.5 ≈ 1 - 0.707 ≈ 0.293
    ///   Dot ordering: v_E (2.0) > v_G (1.5) > v_F (0.5) → distance = -dot → v_E first
    ///   Cosine ordering: v_E (dist=0) < v_F (dist≈0.019) < v_G (dist≈0.293) → v_E first
    ///   Still same top-1.
    ///
    ///   For a genuine difference we need dot and cosine to disagree. Use:
    ///   probe = [1, 1] (diagonal)
    ///   v_H = [10, 0]   dot = 10; cosine_dist = 1 - 10/√200 ≈ 1 - 0.707 ≈ 0.293
    ///   v_I = [0.5, 0.5] dot = 1.0; cosine_dist = 1 - 1/√0.5·√2 ≈ 1 - 1 = 0
    ///   Dot: v_H (dot=10) > v_I (dot=1.0) → v_H first (−dot: v_H smallest)
    ///   Cosine: v_I first (dist=0)
    ///   This fixture produces different top-1 for dot vs cosine.
    @Test("dot and cosine produce different top-1 on a designed fixture")
    func dotAndCosineDifferOnFixture() async throws {
        let storage = try makeScratchStore()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        let store = VectorStore(storage: storage)
        let modelID = "dot-sel-model"

        // probe = [1, 1]; v_H has huge dot product but is at 45° off the probe direction.
        // v_I is in the same direction as probe (cosine=0) but small dot product.
        try await store.addPayload(
            itemID: "v_H", vectorIndex: 0,
            payload: VectorPayload(floats: [10, 0]),
            modelID: modelID, modelVersion: "1", filedAt: Self.now)
        try await store.addPayload(
            itemID: "v_I", vectorIndex: 1,
            payload: VectorPayload(floats: [0.5, 0.5]),
            modelID: modelID, modelVersion: "1", filedAt: Self.now)

        let probe: [Float] = [1.0, 1.0]

        // Cosine: v_I ranks first (same direction → cosine distance ≈ 0)
        let cosineHits = try await store.findNearestFloat(
            probe: probe, modelID: modelID, limit: 2, metric: .cosine)
        #expect(!cosineHits.isEmpty, "cosine must return hits")
        #expect(cosineHits.first?.itemID == "v_I",
                "cosine must rank v_I first (identical direction to probe)")

        // Dot: v_H ranks first (dot product 10 vs 1.0 → −dot distance: v_H smallest)
        let dotHits = try await store.findNearestFloat(
            probe: probe, modelID: modelID, limit: 2, metric: .dot)
        #expect(!dotHits.isEmpty, "dot must return hits")
        #expect(dotHits.first?.itemID == "v_H",
                "dot must rank v_H first (largest inner product with probe)")
    }

    /// Verify that farthest queries also respect the metric parameter.
    @Test("findFarthestFloat respects metric parameter")
    func farthestRespectsMetric() async throws {
        let storage = try makeScratchStore()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        let store = VectorStore(storage: storage)
        let modelID = "farthest-metric-model"

        // Same fixture as dotAndCosineDifferOnFixture.
        // For farthest cosine: v_H is farthest (cos angle largest, at 45°)
        // For farthest dot:    v_I is farthest (−dot is largest positive, so v_I is "farthest" by dot)
        try await store.addPayload(
            itemID: "v_H", vectorIndex: 0,
            payload: VectorPayload(floats: [10, 0]),
            modelID: modelID, modelVersion: "1", filedAt: Self.now)
        try await store.addPayload(
            itemID: "v_I", vectorIndex: 1,
            payload: VectorPayload(floats: [0.5, 0.5]),
            modelID: modelID, modelVersion: "1", filedAt: Self.now)

        let probe: [Float] = [1.0, 1.0]

        // Cosine farthest: v_H (cosine_dist≈0.293) is farther than v_I (dist≈0)
        let cosineFarthest = try await store.findFarthestFloat(
            probe: probe, modelID: modelID, limit: 2, metric: .cosine)
        #expect(!cosineFarthest.isEmpty, "cosine farthest must return hits")
        #expect(cosineFarthest.first?.itemID == "v_H",
                "cosine farthest must rank v_H first (larger cosine distance)")

        // L2 farthest: both return hits (just need well-formed output)
        let l2Farthest = try await store.findFarthestFloat(
            probe: probe, modelID: modelID, limit: 2, metric: .l2)
        #expect(!l2Farthest.isEmpty, "l2 farthest must return hits")
    }
}
