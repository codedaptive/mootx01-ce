// MatrixC.swift
//
// Correlation matrix C per cookbook § 6.2.
//
// C is a dense 2D array, same shape as F (216 cells), holding
// the marginal probability of each (field, bit_position):
//
//   C[field, bit] = F[field, bit] / N_rows
//
// where N_rows is the count of rows in the estate excluding
// tombstoned rows. C is derived (not independently mutated); it
// is recomputed periodically (cookbook recommends weekly,
// realistic for personal estates) by the dreaming daemon, or on
// demand by `derive(from:)`.
//
// Storage: flat [Float] of length 216. Float32 per cookbook
// (sufficient resolution for marginals; Float64 would be wasteful
// here and would introduce bit-identity hazards for the cross-
// language conformance gate, which requires Double bit-pattern
// matching).
//
// Decay: C does NOT decay (cookbook § 6.8 table). It is derived
// from F, which also does not decay.

import Foundation

public struct MatrixC: Sendable, Equatable {

    public static let cellCount = MatrixF.cellCount  // 216

    /// Marginal probabilities. cells[i] in [0, 1] under normal
    /// operation, but the type does not enforce the bound (a
    /// pathological F with negative cells could produce negative
    /// C; that indicates a bug in F's update rule, not in C).
    public private(set) var cells: [Float]

    public init() {
        self.cells = [Float](repeating: 0, count: Self.cellCount)
    }

    public init(cells: [Float]) {
        precondition(cells.count == Self.cellCount,
                     "MatrixC requires exactly \(Self.cellCount) cells")
        self.cells = cells
    }

    // MARK: - Indexing

    public subscript(field: Int, bit: Int) -> Float {
        get { return cells[MatrixF.cellIndex(field: field, bit: bit)] }
        set { cells[MatrixF.cellIndex(field: field, bit: bit)] = newValue }
    }

    // MARK: - Derivation

    /// Compute C from F and N_rows. If N_rows is zero, every cell
    /// is set to zero (no rows ⇒ no marginals).
    ///
    /// Bit-identity note: division of Int64 → Float32 is the
    /// arithmetic source of cross-language hazard. Both Swift and
    /// Rust implement this as:
    ///   1. Cast Int64 cell to Double.
    ///   2. Divide by Double(N_rows).
    ///   3. Cast result to Float32.
    /// The two casts and the division all produce identical
    /// IEEE-754 bit patterns in both languages because IEEE-754
    /// pins them.
    public static func derive(from F: MatrixF, nRows: Int64) -> MatrixC {
        var out = MatrixC()
        if nRows == 0 {
            return out
        }
        let denom = Double(nRows)
        for i in 0..<Self.cellCount {
            let v = Double(F.cells[i]) / denom
            out.cells[i] = Float(v)
        }
        return out
    }

    // MARK: - Canonical wire form
    //
    // 216 × 4 bytes = 864 bytes, IEEE-754 Float32 LE bit-patterns.

    public static let wireBytes = cellCount * 4

    public func writeWire(into bytes: inout [UInt8]) {
        for cell in cells {
            let u = cell.bitPattern
            for i in 0..<4 {
                bytes.append(UInt8((u >> (i * 8)) & 0xFF))
            }
        }
    }

    public static func readWire(_ bytes: [UInt8]) -> MatrixC? {
        guard bytes.count == wireBytes else { return nil }
        var cells = [Float](repeating: 0, count: cellCount)
        for i in 0..<cellCount {
            var u: UInt32 = 0
            for j in 0..<4 {
                u |= UInt32(bytes[i * 4 + j]) << (j * 8)
            }
            cells[i] = Float(bitPattern: u)
        }
        return MatrixC(cells: cells)
    }
}

// MARK: - Properties
//
//   derived-from-F:  derive(from: F, nRows: n) is a pure function;
//                    same (F, n) ⇒ same C in both languages.
//   zero-rows:       derive(from: F, nRows: 0) returns the zero matrix
//                    regardless of F.
//   monotonicity:    if F has only non-negative cells and N_rows > 0,
//                    then C is in [0, 1] at every cell (the actual
//                    upper bound is N_set_in_estate / N_rows ≤ 1).
//
// MARK: - Cookbook references
//   § 6.2   Correlation matrix C definition
//   § 6.8   Matrix decay table (C has half_life = None; derived from F)
//   § 18.2  Conformance: Float32 bit-identity required across languages
