// ThreeDBitTensorTests.swift
//
// Per-type suite for ThreeDBitTensor (bit-sliced 3D hot-path tensor,
// cookbook §4.1). The Rust `bit_tensor.rs` module carries no inline
// tests; this suite asserts the contract from source: value round-trip
// through the six bit-slices, the bit-sliced field-equals scan and its
// match enumeration, and capacity growth preserving existing data.

import Testing
@testable import SubstrateTypes

@Suite("ThreeDBitTensor bit-sliced tensor")
struct ThreeDBitTensorTests {

    @Test("setValue / valueAt round-trips a 6-bit value")
    func valueRoundTrip() {
        var t = ThreeDBitTensor(rowCount: 8)
        t.setValue(row: 3, field: 12, value: 0b101010)   // 42
        #expect(t.valueAt(row: 3, field: 12) == 42)
        // unset cells read zero
        #expect(t.valueAt(row: 0, field: 0) == 0)
        #expect(t.valueAt(row: 3, field: 11) == 0)
    }

    @Test("each bit position is addressable independently")
    func bitLevelAccess() {
        var t = ThreeDBitTensor(rowCount: 4)
        t.setBit(row: 1, field: 5, bit: 2, on: true)
        #expect(t.bitSet(row: 1, field: 5, bit: 2))
        #expect(!t.bitSet(row: 1, field: 5, bit: 0))
        #expect(t.valueAt(row: 1, field: 5) == 0b100)
        t.setBit(row: 1, field: 5, bit: 2, on: false)
        #expect(!t.bitSet(row: 1, field: 5, bit: 2))
    }

    @Test("scanFieldEquals + enumerateMatches finds exactly the matching rows")
    func scanFieldEquals() {
        var t = ThreeDBitTensor(rowCount: 10)
        t.setValue(row: 2, field: 7, value: 33)
        t.setValue(row: 5, field: 7, value: 33)
        t.setValue(row: 8, field: 7, value: 7)   // different value
        let mask = t.scanFieldEquals(field: 7, value: 33)
        #expect(t.enumerateMatches(mask) == [2, 5])
    }

    @Test("a scan for a value present in no row matches nothing")
    func scanNoMatch() {
        var t = ThreeDBitTensor(rowCount: 4)
        t.setValue(row: 0, field: 0, value: 1)
        let mask = t.scanFieldEquals(field: 0, value: 63)
        #expect(t.enumerateMatches(mask).isEmpty)
    }

    @Test("reserveCapacity grows row count and preserves existing data")
    func reserveCapacityPreservesData() {
        var t = ThreeDBitTensor(rowCount: 4)
        t.setValue(row: 1, field: 0, value: 21)
        t.reserveCapacity(64)
        #expect(t.rowCount == 64)
        #expect(t.valueAt(row: 1, field: 0) == 21)   // preserved
        #expect(t.valueAt(row: 40, field: 0) == 0)   // new rows clear
    }

    @Test("byteSize is six bit-slices of ceil(rowCount·36 / 8) bytes")
    func byteSizeMatchesLayout() {
        let t = ThreeDBitTensor(rowCount: 8)
        let bytesPerSlice = (8 * 36 + 7) / 8   // 36
        #expect(t.byteSize == 6 * bytesPerSlice)
    }
}
