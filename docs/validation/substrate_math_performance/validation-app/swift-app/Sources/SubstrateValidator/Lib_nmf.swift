// Lib_nmf.swift
//
// Lib-side conformance CRC for the `nmf` primitive (cookbook §6.9) —
// non-negative matrix factorization via multiplicative-update
// alternating least squares (Lee-Seung). Computes the canonical CRC
// by calling the SHIPPING lib SubstrateML.NMFAlternatingLeastSquares,
// not the glref reference, so the validator can report lib-vs-glref
// drift on the factorize entry point.
//
// Byte mechanism mirrors Harness NMFPrimitive.validateCase exactly:
// for each case we decode the inputs, call the shipping factorize with
// the SAME parameters the harness passes (rank, maxIterations,
// tolerance, seed), and encode the COMPUTED result (iterations,
// finalError, W, H) — not the committed expected_output. Encoding the
// recomputed result is what surfaces lib-vs-glref drift: if the
// shipping factorize diverges by a single f32 ulp from the reference,
// the byte stream (and thus the CRC) differs.
//
//   Input schema (per case):
//     m              : u32 hex (matrix rows)        — present, not read
//     n              : u32 hex (matrix cols)        — present, not read
//     rank           : u32 hex                      — factorize rank
//     max_iterations : u32 hex                      — factorize maxIterations
//     tolerance      : f32 hex                      — factorize tolerance
//     inner_seed     : u64 hex                      — factorize seed (NOT
//                                                      the vector-gen seed)
//     v              : array of arrays of f32 (m × n matrix); each cell an
//                      8-hex-digit IEEE-754 little-endian bit pattern
//
//   Output encode order (must match harness validateCase byte-for-byte):
//     writeU32(iterations)        — 4-byte LE
//     writeF32(final_error)       — 4-byte LE IEEE-754 bit pattern
//     W rows, row-major (m × rank), each cell writeF32   ← W FIRST
//     H rows, row-major (rank × n), each cell writeF32   ← H SECOND
//
// Note on byte sensitivity: NMF is f32, iterative, and ordering-
// sensitive. Bit-identical W/H require the same SplitMix64 seed, the
// same number of init draws, the same multiplicative-update loop order,
// and the same operand order in every f32 multiply/add. We therefore
// replicate the harness's exact call (same params) and exact encode
// (iterations, final_error, then W then H, all in case order). Matrix
// cells use no per-cell length prefix — the encoder writes the f32
// bytes back-to-back; dimensions are implied by the W (m × rank) and
// H (rank × n) shapes the factorize returns.
//
// Malformed input is skipped without writing, mirroring the harness
// `guard ... else { return fail }` (failed cases write no canonical
// bytes).

import Foundation
import Harness
import SubstrateML

enum Lib_nmf {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases { nmfEncodeCase(c, enc: &enc) }
        return CRC32.compute(enc.bytes)
    }

    /// Decode the inputs, call the shipping
    /// SubstrateML.NMFAlternatingLeastSquares.factorize with the same
    /// parameters the harness uses, and encode the recomputed result
    /// (iterations, final_error, W, H). Any decode failure returns
    /// early without writing, matching the harness's failed-case
    /// behavior (no canonical bytes emitted).
    private static func nmfEncodeCase(_ c: VectorFile.Case,
                                      enc: inout CanonicalBinaryEncoder) {
        guard let rank = nmfParseU32(c.inputs.get("rank")),
              let maxIterations = nmfParseU32(c.inputs.get("max_iterations")),
              let tolerance = nmfParseF32(c.inputs.get("tolerance")),
              let innerSeed = nmfParseU64(c.inputs.get("inner_seed")) else { return }

        guard case .array(let vRows) = c.inputs.get("v") ?? .null else { return }
        var V = [[Float32]]()
        V.reserveCapacity(vRows.count)
        for row in vRows {
            guard case .array(let cells) = row else { return }
            var r = [Float32]()
            r.reserveCapacity(cells.count)
            for cell in cells {
                guard case .string(let s) = cell,
                      let f = nmfParseF32Hex(s) else { return }
                r.append(f)
            }
            V.append(r)
        }

        // Shipping API:
        //   SubstrateML.NMFAlternatingLeastSquares.factorize(
        //       V:rank:maxIterations:tolerance:seed:) -> NMFFactorization
        // Same function/signature as the glref reference the harness
        // calls; the only difference is the module it resolves from.
        // .iterations, .finalError, .W (m × rank), .H (rank × n) are the
        // result fields the harness encodes.
        let result = NMFAlternatingLeastSquares.factorize(
            V: V, rank: Int(rank),
            maxIterations: Int(maxIterations),
            tolerance: tolerance,
            seed: innerSeed)

        // Exact harness encode order: iterations (u32), final_error
        // (f32), then every W cell, then every H cell — all row-major.
        enc.writeU32(UInt32(result.iterations))
        enc.writeF32(result.finalError)
        for row in result.W { for v in row { enc.writeF32(v) } }
        for row in result.H { for v in row { enc.writeF32(v) } }
    }

    // MARK: - Hex decoders (mirror harness NMFPrimitive parsers)

    /// Decode an 8-char little-endian hex string into a u32: byte i
    /// contributes bits [i*8, i*8+8). Returns nil on wrong length /
    /// malformed hex.
    private static func nmfParseU32(_ v: JSONValue?) -> UInt32? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt32(b) << (i * 8) }
        return bits
    }

    /// Decode a 16-char little-endian hex string into a u64 (the
    /// factorize seed). Returns nil on wrong length / malformed hex.
    private static func nmfParseU64(_ v: JSONValue?) -> UInt64? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return bits
    }

    /// Decode a JSONValue string into a Float32 by its IEEE-754 bit
    /// pattern.
    private static func nmfParseF32(_ v: JSONValue?) -> Float32? {
        guard case .string(let s)? = v else { return nil }
        return nmfParseF32Hex(s)
    }

    /// Decode an 8-char little-endian hex string into a Float32 by its
    /// IEEE-754 bit pattern: 4 bytes, byte i contributes bits
    /// [i*8, i*8+8). Returns nil on wrong length / malformed hex.
    private static func nmfParseF32Hex(_ s: String) -> Float32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt32(b) << (i * 8) }
        return Float32(bitPattern: bits)
    }
}
