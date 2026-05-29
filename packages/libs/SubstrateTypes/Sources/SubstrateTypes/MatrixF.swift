// MatrixF.swift
//
// Field-presence matrix F per cookbook § 6.1.
//
// F is a dense 2D array indexed by (field_index, bit_position),
// counting the number of rows in the estate where each
// (field, bit) is set. v0.36 has 36 fields × 6 bits = 216 cells.
//
// Storage: flat [Int64] of length 216, indexed
// `field_index * BITS_PER_FIELD + bit_position`.
//
// Update rule (cookbook § 6.1):
//   On row capture, for each (field, bit_position) where the
//   row's bitmap has the bit set, F[field, bit] += 1.
//   On row expunge of an active row, F[field, bit] -= 1.
//   On mutate, the delta is the difference between old and new
//   bit-presence states.
//
// Decay: F does NOT decay (cookbook § 6.8 table). It is a
// population statistic; halving it would lose information.

import Foundation

public struct MatrixF: Sendable, Equatable {

    // Phase 6 dedup: the 36×6 row layout has a canonical home in
    // RowBitmaps. MatrixF aliases these so the constants exist in
    // exactly one place per type system. (The values must match
    // RowBitmaps' by definition — they describe the same cookbook §2.3
    // layout — so an inequality here is a load-time crash, by design.)
    public static let fieldCount = RowBitmaps.fieldCount       // 36
    public static let bitsPerField = RowBitmaps.bitsPerField   // 6
    public static let cellCount = RowBitmaps.totalBits         // 216

    /// Flat storage. cells[field * 6 + bit] = count of rows where
    /// that bit is set in field's encoding.
    public private(set) var cells: [Int64]

    public init() {
        self.cells = [Int64](repeating: 0, count: Self.cellCount)
    }

    public init(cells: [Int64]) {
        precondition(cells.count == Self.cellCount,
                     "MatrixF requires exactly \(Self.cellCount) cells")
        self.cells = cells
    }

    // MARK: - Indexing

    @inlinable
    public static func cellIndex(field: Int, bit: Int) -> Int {
        precondition((0..<fieldCount).contains(field),
                     "field index \(field) out of range")
        precondition((0..<bitsPerField).contains(bit),
                     "bit position \(bit) out of range")
        return field * bitsPerField + bit
    }

    public subscript(field: Int, bit: Int) -> Int64 {
        get { return cells[Self.cellIndex(field: field, bit: bit)] }
        set { cells[Self.cellIndex(field: field, bit: bit)] = newValue }
    }

    // MARK: - Update rules

    /// Apply a row's bitmap-tier presence to the matrix.
    /// `delta` is +1 on capture, -1 on expunge. For mutate, call
    /// twice: once with -1 against the old bitmap, once with +1
    /// against the new bitmap.
    ///
    /// Phase 5 (decision 2026-05-28 §6.5): takes `BitVector216`
    /// (the dense 216-bit view) instead of a closure. Eliminates
    /// the per-call allocation of the closure and centralizes
    /// the field/bit layout in `RowBitmaps`.
    public mutating func applyRow(delta: Int64,
                                   bitVector: BitVector216) {
        guard delta != 0 else { return }
        for field in 0..<Self.fieldCount {
            for bit in 0..<Self.bitsPerField {
                if bitVector.bit(field: field, bit: bit) {
                    cells[Self.cellIndex(field: field, bit: bit)] &+= delta
                }
            }
        }
    }

    /// Total number of bit-presences recorded across all cells.
    /// Useful as a sanity check (should equal N_rows times the
    /// average bits-set-per-row).
    public var totalCount: Int64 {
        var sum: Int64 = 0
        for c in cells { sum &+= c }
        return sum
    }

    public mutating func reset() {
        for i in 0..<Self.cellCount { cells[i] = 0 }
    }

    // MARK: - Canonical wire form
    //
    // 216 × 8 bytes = 1728 bytes, all LE.

    public static let wireBytes = cellCount * 8

    public func writeWire(into bytes: inout [UInt8]) {
        for cell in cells {
            let u = UInt64(bitPattern: cell)
            for i in 0..<8 {
                bytes.append(UInt8((u >> (i * 8)) & 0xFF))
            }
        }
    }

    public static func readWire(_ bytes: [UInt8]) -> MatrixF? {
        guard bytes.count == wireBytes else { return nil }
        var cells = [Int64](repeating: 0, count: cellCount)
        for i in 0..<cellCount {
            var u: UInt64 = 0
            for j in 0..<8 {
                u |= UInt64(bytes[i * 8 + j]) << (j * 8)
            }
            cells[i] = Int64(bitPattern: u)
        }
        return MatrixF(cells: cells)
    }
}

// MARK: - Properties
//
//   linearity:   applyRow with delta=k followed by applyRow with
//                delta=-k restores the original matrix (modulo
//                overflow, which the &+= guards against).
//   monotone-on-capture: with only delta=+1 applications, every
//                cell is non-negative.
//   reset-idempotent: reset() applied twice equals reset() applied
//                once.
//
// MARK: - Cookbook references
//   § 6.1   Field-presence matrix F definition
//   § 6.8   Matrix decay table (F has half_life = None)
//   § A.1   Constitutional invariants I-1 through I-14
