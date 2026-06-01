// RowBitmaps.swift
//
// Phase 5 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.5)
//
// The substrate's row-level adjective/operational/provenance
// bitmap layout, made explicit as a value type. Centralizes the
// 36/6/3 layout literals that previously appeared inline in
// Verbs.swift (`12`, `24`, `6`, `0x3F`) and Substrate.rowHasBit.
//
// Layout (cookbook §2.3 / §2.4 / §2.5):
//   Three flat Int64 columns, each holding named bit-fields at
//   specific bit positions. The abstract 36-field / 6-bit-per-field
//   grid used for matrix-F indexing maps as:
//
//     adjective    fields  0..<12  → adjective_bitmap  (bits 0–27 used,
//                                    bits 28–63 reserved per §2.3)
//     operational  fields 12..<24  → operational_bitmap (bits 0–30 used,
//                                    bits 26–63 reserved per §2.4)
//     provenance   fields 24..<36  → provenance_bitmap  (bits 0–41 used,
//                                    bits 42–63 reserved per §2.5)
//
// The real named fields do NOT form a uniform 12 × 6-bit grid; they
// are named ranges at specific bit positions. RowBitmaps.field(idx)
// reads them as if the grid were uniform — valid for real row data
// because real fields only use bits 0–27/0–30/0–41 (far below the
// Int64 boundary). For arbitrary 216-bit presence grids (e.g. harness
// conformance cases) use BitVector216(presenceBytes:) directly.
//
// Lens citations:
//   Clojure convergent B   — implicit 36×6 bitmap layout
//                            now explicit
//   APL convergent B       — closure-driven matrix update over
//                            216 cells now a typed view

import Foundation

public struct RowBitmaps: Sendable, Hashable, Codable {

    // MARK: Layout constants — single source of truth.

    public static let fieldCount       = 36
    public static let bitsPerField     = 6
    public static let bitmapsCount     = 3
    public static let fieldsPerBitmap  = 12          // 36 / 3
    public static let totalBits        = 216         // 36 * 6
    public static let fieldValueMask: Int64 = 0x3F   // (1 << 6) - 1

    public let adjective:   Int64
    public let operational: Int64
    public let provenance:  Int64

    @inlinable
    public init(adjective: Int64, operational: Int64, provenance: Int64) {
        self.adjective = adjective
        self.operational = operational
        self.provenance = provenance
    }

    public static let zero = RowBitmaps(adjective: 0, operational: 0, provenance: 0)

    // MARK: 6-bit field value access.

    /// Returns the 6-bit value of field `idx` in 0..<36.
    @inlinable
    public func field(_ idx: Int) -> UInt8 {
        precondition(idx >= 0 && idx < Self.fieldCount,
                     "RowBitmaps.field: index out of range")
        let bitmap: Int64
        let localField: Int
        if idx < Self.fieldsPerBitmap {
            bitmap = adjective;   localField = idx
        } else if idx < 2 * Self.fieldsPerBitmap {
            bitmap = operational; localField = idx - Self.fieldsPerBitmap
        } else {
            bitmap = provenance;  localField = idx - 2 * Self.fieldsPerBitmap
        }
        let shift = localField * Self.bitsPerField
        return UInt8((bitmap >> shift) & Self.fieldValueMask)
    }

    /// Returns whether the `bit`-th bit of field `fieldIdx` is
    /// set (fieldIdx in 0..<36, bit in 0..<6).
    @inlinable
    public func bit(field fieldIdx: Int, bit: Int) -> Bool {
        precondition(bit >= 0 && bit < Self.bitsPerField,
                     "RowBitmaps.bit: bit index out of range")
        return (self.field(fieldIdx) >> bit) & 1 == 1
    }

    /// Yields all (field, value) pairs in field-index order. Used
    /// by MatrixO updates and by the harness for canonical
    /// iteration.
    public func fieldValues() -> [(field: UInt8, value: UInt8)] {
        var out: [(UInt8, UInt8)] = []
        out.reserveCapacity(Self.fieldCount)
        for f in 0..<Self.fieldCount {
            out.append((UInt8(f), self.field(f)))
        }
        return out
    }

    /// Dense 216-bit view, suitable for matrix-update consumers.
    @inlinable
    public func bitVector() -> BitVector216 {
        return BitVector216(rowBitmaps: self)
    }
}

// MARK: - BitVector216

/// Dense 216-bit view for field-presence consumers (e.g. MatrixF).
///
/// Two initializers serve two distinct use-cases:
///
/// `init(rowBitmaps:)` — builds a BitVector216 from a live substrate
/// row. Each of the 36 fields' 6-bit values is read via
/// `RowBitmaps.field(_:)`, which correctly extracts the named-field
/// positions defined in cookbook §2.3/§2.4/§2.5. Because the real
/// bitmap fields only occupy bits 0–27/0–30/0–41 of their Int64
/// columns respectively, the 72-bit logical grid is never reached in
/// practice and no real data is lost. Use this path when updating
/// MatrixF from row-capture/expunge events.
///
/// `init(presenceBytes:)` — builds a BitVector216 from a raw 27-byte
/// (216-bit) presence pattern where bit at absolute index
/// `field * 6 + bit` is packed at `bytes[pos/8]`, bit `pos%8`
/// (LSB-first). This is the layout used by the harness vector format
/// (cookbook §6.1 / HARNESS_REFERENCE §2.3) for `field_presence_matrix_f`
/// conformance cases. Use this path when consuming raw presence data
/// from the harness, network wire, or any source that supplies the
/// full abstract 36×6 grid — including bits at field positions 10,
/// 11, 22, 23, 34, 35 (absolute bits 60–71), which `init(rowBitmaps:)`
/// cannot round-trip through the RowBitmaps Int64 columns.
public struct BitVector216: Sendable, Hashable {

    public static let bitCount = RowBitmaps.totalBits
    public static let byteCount = (bitCount + 7) / 8  // 27 bytes

    @usableFromInline internal let storage: [UInt8]

    /// Initialise from a live substrate row. Reads the 6-bit value of
    /// each of the 36 fields via `RowBitmaps.field(_:)` and maps each
    /// set bit to its absolute position `field * 6 + bit`. Correct for
    /// row-data consumers (capture / expunge / mutate delta against
    /// MatrixF). The upper positions 60–71 of the 216-bit grid reflect
    /// only reserved bits from the Int64 columns and will always be
    /// zero for any conforming row (cookbook §2.3 bits 28–63 reserved,
    /// §2.4 bits 26–63 reserved, §2.5 bits 42–63 reserved).
    @inlinable
    public init(rowBitmaps: RowBitmaps) {
        var s = [UInt8](repeating: 0, count: Self.byteCount)
        for field in 0..<RowBitmaps.fieldCount {
            let v = rowBitmaps.field(field)
            for b in 0..<RowBitmaps.bitsPerField where ((v >> b) & 1) == 1 {
                let abs = field * RowBitmaps.bitsPerField + b
                s[abs / 8] |= UInt8(1 << (abs % 8))
            }
        }
        self.storage = s
    }

    /// Initialise from a raw 27-byte presence pattern (216 bits packed
    /// LSB-first). Bit at absolute index `pos = field * 6 + bit` is
    /// stored at `bytes[pos / 8]`, bit `pos % 8`. This is the canonical
    /// layout for the `bit_presence` field in harness vector cases for
    /// `field_presence_matrix_f` (cookbook §6.1). Use this path when
    /// building a BitVector216 from raw presence data — in particular
    /// when the presence pattern may have bits set at positions 60–71
    /// (fields 10/11/22/23/34/35) that cannot be encoded in a
    /// RowBitmaps value.
    ///
    /// Precondition: `presenceBytes.count == BitVector216.byteCount` (27).
    @inlinable
    public init(presenceBytes: [UInt8]) {
        precondition(presenceBytes.count == Self.byteCount,
                     "BitVector216.init(presenceBytes:): must be exactly \(Self.byteCount) bytes")
        self.storage = presenceBytes
    }

    /// Bit at absolute index 0..<216.
    @inlinable
    public func bit(at index: Int) -> Bool {
        precondition(index >= 0 && index < Self.bitCount,
                     "BitVector216.bit: index out of range")
        return (storage[index / 8] >> UInt8(index % 8)) & 1 == 1
    }

    /// Bit at (field, bit) — convenience for the consumer that
    /// thinks in row-bitmap coordinates rather than absolute index.
    @inlinable
    public func bit(field: Int, bit: Int) -> Bool {
        return self.bit(at: field * RowBitmaps.bitsPerField + bit)
    }
}
