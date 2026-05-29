// ThreeDBitTensor.swift
//
// Three-dimensional bit-sliced tensor per cookbook § 4.1 and
// paper § 11.1.
//
// The substrate's hot path is a 3D binary tensor with axes:
//
//   axis 0 (row):     up to N_rows rows (typical 1M)
//   axis 1 (field):   36 fields across the three bitmap columns
//   axis 2 (bit):     6 bits per field (the invariant I-6 width)
//
// Layout: bit-sliced by axis-2-bit (cookbook § 4.1.3). For each
// bit position b ∈ {0..5}, we keep a Bitmap of N_rows × 36 bits,
// where row r's field f has its b-th bit at offset r·36 + f.
// Storage is six Bitmaps (one per bit position), each of size
// ceil(N_rows · 36 / 8) bytes.
//
// Scan operations: a query like "rows where field 12 has value
// 5" decomposes into per-bit predicates (bit0=1, bit1=0, bit2=1)
// that are computed in parallel via bitwise AND of the relevant
// bit-slices. The whole scan is O(N_rows / 64) word operations
// regardless of the value being matched.
//
// Memory cost (1M rows × 36 fields × 6 bits): 27 MiB. Within the
// LPDDR5 working-set budget of Apple silicon and well within
// cache hierarchies for ~10K row sub-scans.
//
// Used by:
//   § 4.1 cookbook   3D bit-tensor definition (this file)
//   § 11.1 paper     Hot-path layout
//   § 4.2 cookbook   Memory-mapped working set (consumer)
//   § 11.2 paper     Memory layout details

import Foundation

public struct ThreeDBitTensor: Sendable {
    public static let fieldCount = 36
    public static let bitsPerField = 6

    public private(set) var rowCount: Int
    /// Six bit-slices, one per bit position [0..5]. Each slice is
    /// a flat byte buffer of length ceil(rowCount * 36 / 8).
    public var slices: [[UInt8]]

    public init(rowCount: Int) {
        precondition(rowCount > 0, "rowCount must be positive")
        self.rowCount = rowCount
        let bitsPerSlice = rowCount * Self.fieldCount
        let bytesPerSlice = (bitsPerSlice + 7) / 8
        self.slices = Array(repeating: Array(repeating: 0, count: bytesPerSlice),
                            count: Self.bitsPerField)
    }

    // ---- Cell-level access ----

    /// Read the value (0..63) at (row, field).
    public func valueAt(row: Int, field: Int) -> UInt8 {
        precondition(row >= 0 && row < rowCount, "row out of range")
        precondition(field >= 0 && field < Self.fieldCount, "field out of range")
        var v: UInt8 = 0
        for b in 0..<Self.bitsPerField {
            if bitSet(row: row, field: field, bit: b) {
                v |= UInt8(1 << b)
            }
        }
        return v
    }

    /// Write the value (0..63) at (row, field). MUST be < 64
    /// (invariant I-6: 6-bit field width).
    public mutating func setValue(row: Int, field: Int, value: UInt8) {
        precondition(row >= 0 && row < rowCount, "row out of range")
        precondition(field >= 0 && field < Self.fieldCount, "field out of range")
        precondition(value < 64, "value must fit in 6 bits (I-6)")
        for b in 0..<Self.bitsPerField {
            let bitOn = (value >> b) & 1 == 1
            setBit(row: row, field: field, bit: b, on: bitOn)
        }
    }

    // ---- Bit-level helpers ----

    @inlinable
    public func bitSet(row: Int, field: Int, bit: Int) -> Bool {
        let bitIndex = row * Self.fieldCount + field
        let byteIndex = bitIndex / 8
        let bitInByte = bitIndex % 8
        return (slices[bit][byteIndex] >> bitInByte) & 1 == 1
    }

    public mutating func setBit(row: Int, field: Int, bit: Int, on: Bool) {
        let bitIndex = row * Self.fieldCount + field
        let byteIndex = bitIndex / 8
        let bitInByte = bitIndex % 8
        if on {
            slices[bit][byteIndex] |= UInt8(1 << bitInByte)
        } else {
            slices[bit][byteIndex] &= ~UInt8(1 << bitInByte)
        }
    }

    // ---- Bit-sliced scans ----

    /// Find all rows where field f has value v. O(rowCount / 8)
    /// byte operations per bit position; six bit positions total.
    /// Returns a byte buffer mask of length ceil(rowCount / 8) bits.
    public func scanFieldEquals(field: Int, value: UInt8) -> [UInt8] {
        precondition(field >= 0 && field < Self.fieldCount, "field out of range")
        precondition(value < 64, "value must fit in 6 bits")
        let maskBytes = (rowCount + 7) / 8
        var match = Array<UInt8>(repeating: 0xFF, count: maskBytes)
        for b in 0..<Self.bitsPerField {
            let bitOn = (value >> b) & 1 == 1
            for row in 0..<rowCount {
                let actual = bitSet(row: row, field: field, bit: b)
                if actual != bitOn {
                    match[row / 8] &= ~UInt8(1 << (row % 8))
                }
            }
        }
        return match
    }

    /// Enumerate the matching row indices from a scan mask.
    public func enumerateMatches(_ mask: [UInt8]) -> [Int] {
        var hits: [Int] = []
        for row in 0..<rowCount {
            if (mask[row / 8] >> (row % 8)) & 1 == 1 {
                hits.append(row)
            }
        }
        return hits
    }

    // ---- Capacity management ----

    /// Reserve additional row capacity. Existing data preserved.
    public mutating func reserveCapacity(_ newRowCount: Int) {
        guard newRowCount > rowCount else { return }
        let bitsPerSlice = newRowCount * Self.fieldCount
        let bytesPerSlice = (bitsPerSlice + 7) / 8
        for b in 0..<Self.bitsPerField {
            slices[b].append(contentsOf:
                Array(repeating: 0, count: bytesPerSlice - slices[b].count))
        }
        rowCount = newRowCount
    }

    public var byteSize: Int {
        return slices.reduce(0) { $0 + $1.count }
    }
}
