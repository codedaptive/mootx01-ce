// Lib_field_presence_matrix_f.swift
//
// Lib-side conformance CRC for the `field_presence_matrix_f`
// primitive (cookbook §6.1). Computes the canonical CRC by exercising
// the SHIPPING lib — SubstrateTypes.MatrixF — rather than the glref
// reference (glref-swift-MatrixF.swift), so the validator can report
// lib-vs-glref drift on the field-presence matrix update path.
//
// Byte mechanism mirrors Harness FieldPresenceMatrixFPrimitive
// .validateCase exactly:
//
//   Input schema:
//     initial_cells : .array of i64 (length 216) — initial F state.
//     operations    : .array of {bit_presence: 54-hex (27 bytes),
//                     delta: i64}.
//   Output schema:
//     final_cells : .array of i64 (length 216) — F after all ops.
//
//   Canonical output encoding (single field, so no key ordering to
//   resolve): writeU32(216) length prefix, then 216 × writeI64 of
//   the final cells in flat (field * 6 + bit) order. Identical to the
//   harness's encodeOutput / validateCase encoder writes.
//
// MatrixF is a population statistic: 36 fields × 6 bits-per-field =
// 216 i64 cells, indexed cells[field * 6 + bit]. The canonical update
// walks the 216 (field, bit) positions and adds `delta` to each cell
// whose bit-presence is set. Inverse operations cancel (linearity).
// MatrixF does NOT decay (cookbook §6.8 has F's half_life = None).
// Integer-only (i64 wrapping addition), so Apple and non-Apple
// platforms agree bit-for-bit.
//
// The 27-byte bit_presence pattern packs bit `field * 6 + bit` at byte
// `pos / 8`, bit `pos % 8` (LSB-first). That absolute index is exactly
// what glref's closure reads — `bitPresence(field, bit)` is true iff
// the bit at `field * 6 + bit` is set — so the canonical per-cell
// presence is the absolute-indexed pattern bit, nothing more.
//
// This path routes through BitVector216(presenceBytes:) and the
// shipping MatrixF.applyRow(delta:bitVector:). The 27-byte raw
// bit_presence pattern from the harness vector is fed directly into
// BitVector216(presenceBytes:) (added in the v0.8 lib refresh),
// which stores the 216 bits verbatim — including bits at absolute
// positions 60–71 (fields 10/11/22/23/34/35) that cannot be encoded
// via RowBitmaps. applyRow then walks all 216 (field, bit) positions
// using BitVector216.bit(field:bit:), matching glref's per-cell
// closure logic exactly. The output is byte-identical to glref.

import Foundation
import Harness
import SubstrateTypes

enum Lib_field_presence_matrix_f {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            fpmfEncodeCase(c, enc: &enc)
        }
        return CRC32.compute(enc.bytes)
    }

    /// Decode initial_cells + operations, run the shipping MatrixF
    /// update, and write the final cells as writeU32(count) + N×
    /// writeI64. On malformed input we skip without writing, mirroring
    /// the harness `guard ... else { return fail }` (failed cases write
    /// no canonical bytes).
    private static func fpmfEncodeCase(_ c: VectorFile.Case,
                                       enc: inout CanonicalBinaryEncoder) {
        guard case .array(let initArr) = c.inputs.get("initial_cells") ?? .null,
              initArr.count == MatrixF.cellCount else { return }
        var initialCells = [Int64](repeating: 0, count: MatrixF.cellCount)
        for (idx, v) in initArr.enumerated() {
            guard case .integer(let n) = v else { return }
            initialCells[idx] = n
        }

        guard case .array(let opsArr) = c.inputs.get("operations") ?? .null else { return }
        var ops = [fpmfOperation]()
        ops.reserveCapacity(opsArr.count)
        for ov in opsArr {
            guard case .dict(let od) = ov else { return }
            guard case .integer(let delta) = od.get("delta") ?? .null else { return }
            guard case .string(let bpHex) = od.get("bit_presence") ?? .null,
                  let bp = try? HexCoding.decode(bpHex),
                  bp.count == fpmfBitPresenceBytes else { return }
            ops.append(fpmfOperation(delta: delta, bitPresence: bp))
        }

        let finalCells = fpmfApplyOps(initial: initialCells, ops: ops)

        // Canonical output: u32 LE length prefix (216) + 216 × i64 LE.
        enc.writeU32(UInt32(finalCells.count))
        for v in finalCells { enc.writeI64(v) }
    }

    // MARK: - Algorithm (shipping MatrixF)

    private struct fpmfOperation {
        let delta: Int64
        /// 216 bits packed LSB-first into 27 bytes.
        let bitPresence: [UInt8]
    }

    /// 216 bits / 8 = 27 bytes per bit_presence pattern.
    private static let fpmfBitPresenceBytes = 27

    private static func fpmfApplyOps(initial: [Int64],
                                     ops: [fpmfOperation]) -> [Int64] {
        var matrix = MatrixF(cells: initial)
        for op in ops {
            // BitVector216(presenceBytes:) stores all 216 bits verbatim,
            // including fields 10/11/22/23/34/35 (absolute bits 60–71)
            // that cannot be round-tripped through RowBitmaps. applyRow
            // then walks all 216 (field, bit) positions using the same
            // BitVector216.bit(field:bit:) accessor as the lib — output
            // is byte-identical to glref. (cookbook §6.1)
            let bv = BitVector216(presenceBytes: op.bitPresence)
            matrix.applyRow(delta: op.delta, bitVector: bv)
        }
        return matrix.cells
    }
}
