// RowBitmaps.swift
//
// Phase 5 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.5)
//
// The substrate's row-level adjective/operational/provenance
// bitmap layout, made explicit as a value type. Centralizes the
// 36/6/3 layout literals that previously appeared inline in
// Verbs.swift (`12`, `24`, `6`, `0x3F`) and Substrate.rowHasBit.
//
// Layout (cookbook § 2.3):
//   36 fields, 6 bits per field, packed across three Int64
//   columns of 12 fields each:
//
//     adjective    fields 0..<12   (72 bits used; 64 bits storage; high 8 unused)
//     operational  fields 12..<24
//     provenance   fields 24..<36
//
// The 12-fields × 6-bits = 72 bits per column overflows a single
// Int64 by 8 bits; the substrate accepts this by allocating
// 6 × 12 = 72 bit positions per column with the high 8 bits
// reserved (cookbook §2.3 footnote 2). This file documents that.
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

/// Dense 216-bit view over a `RowBitmaps`. Each bit is the
/// (field, bit) position from cookbook §2.3. Useful when the
/// consumer wants to iterate every present bit (e.g. MatrixF
/// presence-count updates).
public struct BitVector216: Sendable, Hashable {

    public static let bitCount = RowBitmaps.totalBits
    public static let byteCount = (bitCount + 7) / 8  // 27 bytes

    @usableFromInline internal let storage: [UInt8]

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
