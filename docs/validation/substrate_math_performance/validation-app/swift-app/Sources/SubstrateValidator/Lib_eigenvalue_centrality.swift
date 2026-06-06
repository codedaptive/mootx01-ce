// Lib_eigenvalue_centrality.swift
//
// Lib-side conformance CRC for the `eigenvalue_centrality` primitive
// (cookbook §7.2). Computes the canonical CRC by calling the SHIPPING
// lib (SubstrateML.EigenvalueCentrality.compute), not the glref
// reference, so the validator can report lib-vs-glref drift on the
// centrality-vector wire encoding.
//
// Byte mechanism mirrors Harness EigenvalueCentralityPrimitive.validateCase
// exactly (its CRC-accumulation path): for each case, decode n + edges +
// max_iterations + tolerance, build the sparse adjacency in edges-array
// order, call EigenvalueCentrality.compute, then emit
// `encoder.writeU32(count)` followed by one `encoder.writeF64(v)` per
// element. The f64 write is the IEEE-754 bit pattern (LE), the u32 is the
// vector length prefix. CRC32 over the accumulated bytes (all cases
// concatenated in case order) must equal the committed outputCrc32.
//
// Input schema (per case):
//   n              : u32  (decimal JSON integer)
//   edges          : array of {dst: u32 int, src: u32 int, weight: f64 hex}
//   max_iterations : u32  (decimal JSON integer)
//   tolerance      : f64  (16-hex IEEE-754 bit pattern, LE)
//
// Output (per case, accumulated into the shared encoder):
//   centrality : u32 LE length prefix, then N × 8-byte f64 LE (bit pattern).
//
// Edge-order discipline: edges are folded into the adjacency in JSON-array
// order — adjacency[src] receives entries in the order they appear in the
// edges array. The inner accumulation `x_next[j] += w * x[i]` therefore
// proceeds in the same loop order as the harness and the Rust port, so the
// floating-point reduction is bit-identical. compute() uses sqrt(), which
// is IEEE-754 correctly-rounded across conformant libm, so the result and
// the convergence-detection iteration match across ports.
//
// Shipping-vs-glref API note: SubstrateML.EigenvalueCentrality and the
// glref reference are identical here — same enum name, same
// `compute(adjacency:maxIterations:tolerance:)` signature, same
// Adjacency typealias `[[(neighbor: Int, weight: Double)]]`, same
// algorithm (uniform 1/sqrt(n) seed, Perron shift = 1.0, L2 normalize,
// diff-norm < tolerance early exit). No glref-vs-shipping drift in the
// type surface; this lib path exercises the shipping module so any future
// divergence surfaces as a CRC mismatch. No SubstrateKernel symbols are
// referenced, so there is no kernel/protocol module ambiguity here.

import Foundation
import Harness
import SubstrateML

enum Lib_eigenvalue_centrality {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // --- n: decimal JSON integer, non-negative ---
            guard case .integer(let nI) = c.inputs.get("n") ?? .null,
                  let n = Int(exactly: nI), n >= 0
            else { continue }

            // --- max_iterations: decimal JSON integer, positive ---
            guard case .integer(let maxIterI) = c.inputs.get("max_iterations") ?? .null,
                  let maxIter = Int(exactly: maxIterI), maxIter > 0
            else { continue }

            // --- tolerance: 16-hex f64 bit pattern (LE) ---
            guard case .string(let tolHex) = c.inputs.get("tolerance") ?? .null,
                  let tolerance = eigCentParseF64Hex(tolHex)
            else { continue }

            // --- edges: [{dst: int, src: int, weight: f64 hex}] ---
            guard case .array(let edgesArr) = c.inputs.get("edges") ?? .null
            else { continue }

            // Build the sparse adjacency in JSON-array order so the inner
            // accumulation order matches the harness and the Rust port.
            var adjacency: EigenvalueCentrality.Adjacency =
                Array(repeating: [], count: n)
            var malformed = false
            for e in edgesArr {
                guard case .dict(let edgeDict) = e,
                      case .integer(let srcI) = edgeDict.get("src") ?? .null,
                      let src = Int(exactly: srcI), src >= 0, src < n,
                      case .integer(let dstI) = edgeDict.get("dst") ?? .null,
                      let dst = Int(exactly: dstI), dst >= 0, dst < n,
                      case .string(let wHex) = edgeDict.get("weight") ?? .null,
                      let w = eigCentParseF64Hex(wHex)
                else { malformed = true; break }
                adjacency[src].append((neighbor: dst, weight: w))
            }
            if malformed { continue }

            // Shipping power-iteration centrality. Returns the
            // L2-normalized principal eigenvector indexed by row.
            let centrality = EigenvalueCentrality.compute(
                adjacency: adjacency,
                maxIterations: maxIter,
                tolerance: tolerance)

            // Canonical encoding: u32 LE length prefix, then one f64 LE
            // (IEEE-754 bit pattern) per element. Exactly the harness
            // validateCase accumulation path.
            enc.writeU32(UInt32(centrality.count))
            for v in centrality { enc.writeF64(v) }
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (private, eigCent-prefixed to avoid cross-file collisions)

    /// Decode an 8-byte little-endian f64 from its hex bit-pattern string.
    /// Mirrors the harness `parseF64Hex`: byte i contributes bits
    /// [i*8, i*8+8) of the IEEE-754 bit pattern.
    private static func eigCentParseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt64(b) << (i * 8)
        }
        return Double(bitPattern: bits)
    }
}
