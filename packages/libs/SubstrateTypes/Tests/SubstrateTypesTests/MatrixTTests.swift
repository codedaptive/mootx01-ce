// MatrixTTests.swift
//
// Per-type suite for MatrixT (temporal causality matrix) + CausalityKey.
// Mirrors the Rust `matrix_t.rs` inline #[test] set:
// lag_bucket_boundaries, apply_pair_creates_cross_product,
// apply_pair_out_of_range_is_noop, asymmetric_storage, wire_round_trip.

import Testing
@testable import SubstrateTypes

@Suite("MatrixT temporal causality matrix")
struct MatrixTTests {

    @Test("lag-bucket boundaries map minutes to the log-spaced buckets")
    func lagBucketBoundaries() {
        #expect(MatrixT.lagBucket(forMinutes: 0) == nil)
        #expect(MatrixT.lagBucket(forMinutes: 1) == 0)
        #expect(MatrixT.lagBucket(forMinutes: 2) == 1)
        #expect(MatrixT.lagBucket(forMinutes: 3) == 1)
        #expect(MatrixT.lagBucket(forMinutes: 4) == 2)
        #expect(MatrixT.lagBucket(forMinutes: 15) == 3)
        #expect(MatrixT.lagBucket(forMinutes: 16) == 4)
        #expect(MatrixT.lagBucket(forMinutes: 127) == 6)
        #expect(MatrixT.lagBucket(forMinutes: 128) == 7)
        #expect(MatrixT.lagBucket(forMinutes: 255) == 7)
        #expect(MatrixT.lagBucket(forMinutes: 256) == nil)
        #expect(MatrixT.lagBucket(forMinutes: 1000) == nil)
    }

    @Test("applyPair creates the source×target cross product at the lag bucket")
    func applyPairCreatesCrossProduct() {
        var t = MatrixT()
        let a: [(field: UInt8, value: UInt8)] = [(0, 1), (5, 3)]
        let b: [(field: UInt8, value: UInt8)] = [(2, 0)]
        t.applyPair(delta: 1, rowAFieldValues: a, rowBFieldValues: b, lagMinutes: 10) // bucket 3
        #expect(t.entryCount == 2)
        #expect(t.count(CausalityKey(sourceField: 0, sourceValue: 1,
                                     targetField: 2, targetValue: 0, lagBucket: 3)) == 1)
        #expect(t.count(CausalityKey(sourceField: 5, sourceValue: 3,
                                     targetField: 2, targetValue: 0, lagBucket: 3)) == 1)
    }

    @Test("applyPair with an out-of-range lag is a no-op")
    func applyPairOutOfRangeIsNoop() {
        var t = MatrixT()
        let a: [(field: UInt8, value: UInt8)] = [(0, 1)]
        let b: [(field: UInt8, value: UInt8)] = [(2, 0)]
        t.applyPair(delta: 1, rowAFieldValues: a, rowBFieldValues: b, lagMinutes: 300)
        #expect(t.entryCount == 0)
        t.applyPair(delta: 1, rowAFieldValues: a, rowBFieldValues: b, lagMinutes: 0)
        #expect(t.entryCount == 0)
    }

    @Test("storage is asymmetric: (a→b) and (b→a) are distinct cells")
    func asymmetricStorage() {
        var t = MatrixT()
        let keyAB = CausalityKey(sourceField: 0, sourceValue: 1,
                                 targetField: 5, targetValue: 3, lagBucket: 2)
        let keyBA = CausalityKey(sourceField: 5, sourceValue: 3,
                                 targetField: 0, targetValue: 1, lagBucket: 2)
        t.increment(keyAB, by: 3)
        #expect(t.count(keyAB) == 3)
        #expect(t.count(keyBA) == 0)   // distinct cell
    }

    @Test("wire encoding round-trips (positive and negative counts)")
    func wireRoundTrip() throws {
        var t = MatrixT()
        t.increment(CausalityKey(sourceField: 0, sourceValue: 1,
                                 targetField: 2, targetValue: 3, lagBucket: 0), by: 42)
        t.increment(CausalityKey(sourceField: 10, sourceValue: 5,
                                 targetField: 20, targetValue: 4, lagBucket: 7), by: -17)
        var bytes = [UInt8]()
        t.writeWire(into: &bytes)
        let back = try #require(MatrixT.readWire(bytes))
        #expect(back == t)
    }
}
