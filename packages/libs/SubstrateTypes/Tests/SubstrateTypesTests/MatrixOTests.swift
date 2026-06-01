// MatrixOTests.swift
//
// Per-type suite for MatrixO (co-occurrence matrix) + CooccurrenceKey.
// Mirrors the Rust `matrix_o.rs` inline #[test] set:
// empty_matrix_zero_counts, increment_and_query,
// apply_row_diagonal_and_pairs, apply_row_inverse_clears,
// entries_sorted_by_packed_key, wire_round_trip.

import Testing
@testable import SubstrateTypes

@Suite("MatrixO co-occurrence matrix")
struct MatrixOTests {

    @Test("empty matrix reports zero counts and no entries")
    func emptyMatrixZeroCounts() {
        let o = MatrixO()
        #expect(o.count(CooccurrenceKey(fieldI: 0, valueI: 0, fieldJ: 0, valueJ: 0)) == 0)
        #expect(o.entryCount == 0)
    }

    @Test("increment then query; reaching zero drops the cell")
    func incrementAndQuery() {
        var o = MatrixO()
        let k = CooccurrenceKey(fieldI: 3, valueI: 2, fieldJ: 5, valueJ: 4)
        o.increment(k, by: 5)
        #expect(o.count(k) == 5)
        o.increment(k, by: -3)
        #expect(o.count(k) == 2)
        o.increment(k, by: -2)
        #expect(o.count(k) == 0)
        #expect(o.entryCount == 0)   // dropped when zero
    }

    @Test("applyRow creates the full ordered-pair cross product (incl. diagonal)")
    func applyRowDiagonalAndPairs() {
        var o = MatrixO()
        let pairs: [(field: UInt8, value: UInt8)] = [(0, 1), (5, 3)]
        o.applyRow(delta: 1, fieldValues: pairs)
        // Four cells: (0,1)x(0,1), (0,1)x(5,3), (5,3)x(0,1), (5,3)x(5,3).
        #expect(o.entryCount == 4)
        #expect(o.count(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 0, valueJ: 1)) == 1)
        #expect(o.count(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 5, valueJ: 3)) == 1)
        #expect(o.count(CooccurrenceKey(fieldI: 5, valueI: 3, fieldJ: 0, valueJ: 1)) == 1)
        #expect(o.count(CooccurrenceKey(fieldI: 5, valueI: 3, fieldJ: 5, valueJ: 3)) == 1)
    }

    @Test("applyRow(+1) then applyRow(-1) clears the matrix")
    func applyRowInverseClears() {
        var o = MatrixO()
        let pairs: [(field: UInt8, value: UInt8)] = [(0, 1), (5, 3)]
        o.applyRow(delta: 1, fieldValues: pairs)
        o.applyRow(delta: -1, fieldValues: pairs)
        #expect(o.entryCount == 0)
        #expect(o.totalCount == 0)
    }

    @Test("entries stay sorted by packed key")
    func entriesSortedByPackedKey() {
        var o = MatrixO()
        o.increment(CooccurrenceKey(fieldI: 5, valueI: 3, fieldJ: 5, valueJ: 3), by: 1)
        o.increment(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 0, valueJ: 1), by: 1)
        o.increment(CooccurrenceKey(fieldI: 5, valueI: 3, fieldJ: 0, valueJ: 1), by: 1)
        let packed = o.entries.map { $0.key.packed }
        #expect(packed == packed.sorted())
    }

    @Test("wire encoding round-trips (positive and negative counts)")
    func wireRoundTrip() throws {
        var o = MatrixO()
        o.increment(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 5, valueJ: 3), by: 42)
        o.increment(CooccurrenceKey(fieldI: 10, valueI: 5, fieldJ: 20, valueJ: 4), by: -17)
        var bytes = [UInt8]()
        o.writeWire(into: &bytes)
        let back = try #require(MatrixO.readWire(bytes))
        #expect(back == o)
    }
}
