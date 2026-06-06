// Lib_matrix_decay.swift
//
// Conformance CRC for the `matrix_decay` primitive computed against
// the SHIPPING substrate library (SubstrateML.MatrixDecay /
// SubstrateML.DecayingMatrix), not the glref reference. Used to
// confirm the shipping exponential-decay path produces the exact
// same conformance byte stream the harness produces from glref.
//
// Shipping symbols under test (SubstrateML):
//   struct DecayingMatrix { rows, cols, values:[Double],
//                           halfLifeSeconds:Double,
//                           lastDecayTimeSeconds:Int64 }
//   enum MatrixDecay { static func apply(to:nowSeconds:) }
// The shipping `apply` is byte-identical to glref: it computes
//   factor = exp(-dt * Double.ln2 / halfLifeSeconds)
// for dt = nowSeconds - lastDecayTimeSeconds (no-op when dt <= 0),
// scales every cell, and advances lastDecayTimeSeconds to now.
//
// Input schema (mirrors MatrixDecayPrimitive.validateCase):
//   rows                      : u32  (decimal integer)
//   cols                      : u32  (decimal integer)
//   half_life_seconds         : f64  (16-hex IEEE-754 bit pattern, LE)
//   last_decay_time_seconds   : i64  (decimal integer)
//   now_seconds               : i64  (decimal integer)
//   initial_values            : array of f64 (each 16-hex IEEE-754 LE)
//
// Output encoding (mirrors MatrixDecayPrimitive.validateCase
// byte-for-byte; alphabetical key order final_last_decay <
// final_values, so the i64 is written first):
//   writeI64(matrix.lastDecayTimeSeconds)   -> 8 bytes i64 LE
//   writeU32(matrix.values.count)           -> 4 bytes u32 LE length
//   for each cell: writeF64(value)          -> 8 bytes IEEE-754 LE
// The f64 writer emits the raw `Double.bitPattern` as u64 LE, so the
// transcendental `exp` result is compared bit-for-bit. The
// concatenated stream over all cases is CRC32'd to yield the
// conformance value.
//
// Malformed cases are skipped (matching the validator's tolerance);
// only well-formed cases contribute bytes to the CRC.

import Foundation
import Harness
import SubstrateML

enum Lib_matrix_decay {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            guard let decayed = matrixDecayApply(c) else { continue }

            // Same output encoding the harness emits per case:
            // i64 last-decay time, then u32-length-prefixed f64 cells.
            enc.writeI64(decayed.lastDecayTimeSeconds)
            enc.writeU32(UInt32(decayed.values.count))
            for v in decayed.values { enc.writeF64(v) }
        }
        return CRC32.compute(enc.bytes)
    }

    /// Decode one case's inputs, run the shipping decay, and return
    /// the post-decay matrix. Returns nil for any malformed input so
    /// the caller skips it (matching the harness validator).
    private static func matrixDecayApply(_ c: VectorFile.Case) -> DecayingMatrix? {
        guard case .integer(let rowsI) = c.inputs.get("rows") ?? .null,
              let rows = Int(exactly: rowsI), rows > 0 else { return nil }
        guard case .integer(let colsI) = c.inputs.get("cols") ?? .null,
              let cols = Int(exactly: colsI), cols > 0 else { return nil }
        guard case .string(let hlHex) = c.inputs.get("half_life_seconds") ?? .null,
              let halfLife = matrixDecayParseF64Hex(hlHex) else { return nil }
        guard case .integer(let lastDecayTime) = c.inputs.get("last_decay_time_seconds") ?? .null else { return nil }
        guard case .integer(let nowSeconds) = c.inputs.get("now_seconds") ?? .null else { return nil }
        guard case .array(let initArr) = c.inputs.get("initial_values") ?? .null,
              initArr.count == rows * cols else { return nil }

        var initialValues = [Double]()
        initialValues.reserveCapacity(rows * cols)
        for v in initArr {
            guard case .string(let s) = v,
                  let f = matrixDecayParseF64Hex(s) else { return nil }
            initialValues.append(f)
        }

        // Shipping constructor requires positive dims and half-life;
        // those are already validated above.
        var matrix = DecayingMatrix(
            rows: rows, cols: cols,
            halfLifeSeconds: halfLife,
            lastDecayTimeSeconds: lastDecayTime)
        for r in 0..<rows {
            for col in 0..<cols {
                matrix[r, col] = initialValues[r * cols + col]
            }
        }

        // Shipping exponential decay: factor = exp(-dt*ln2/halfLife).
        MatrixDecay.apply(to: &matrix, nowSeconds: nowSeconds)
        return matrix
    }

    /// Decode a 16-hex IEEE-754 LE string into a Double via its
    /// raw 64-bit pattern (no lexical float parsing).
    private static func matrixDecayParseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt64(b) << (i * 8)
        }
        return Double(bitPattern: bits)
    }
}
