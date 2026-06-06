// Lib_lattice.swift
//
// Lib-side conformance CRC for the `lattice` primitive (cookbook §8.3),
// the UDC tree-distance component of lattice distance. Computes the
// canonical CRC by calling the SHIPPING lib (SubstrateML.UDCTreeDistance),
// NOT the glref reference, so the validator can report lib-vs-glref
// drift on the UDC tree-distance path.
//
// Byte mechanism mirrors Harness LatticePrimitive.validate exactly:
//
//   Per case (output schema { distance: f64 }):
//     decode input string `a` (UDC code, dotted decimal) and input
//     string `b`; compute UDCTreeDistance.distance(a, b) via the
//     shipping SubstrateML API; encode the result as an 8-byte
//     IEEE-754 little-endian bit pattern (encoder.writeF64, which is
//     writeU64(v.bitPattern)). One f64 per case — matches the harness
//     validate() per-case encoder.writeF64(actual).
//
// glref-vs-shipping note: SubstrateML.UDCTreeDistance.distance and the
// glref glref-swift-LatticeDistance.swift UDCTreeDistance.distance are
// the same algorithm (longest-common-prefix character distance,
// normalized by max length). The only difference is the module: the
// shipping symbol lives in SubstrateML; glref lives in
// GeniusLocusReference. This file deliberately calls the shipping
// SubstrateML path so any divergence surfaces against the committed
// outputCrc32.
//
// The full LatticeDistance API also covers Wikidata graph distance
// (requires a WikidataAdjacencyProvider) and the composite lattice
// distance. The harness vector exercises only the pure UDC tree
// component, which is the most-used path in the substrate's
// recall-by-place primitive, so this file mirrors that exact surface.

import Foundation
import Harness
import SubstrateML

enum Lib_lattice {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()

        for c in file.cases {
            // Per-case path, identical to harness validate(): read the
            // two UDC strings, compute the shipping distance, encode one
            // f64 LE bit pattern. Malformed cases are skipped so the
            // encoder byte stream stays aligned with the harness, which
            // would have produced a CaseResult fail (no bytes written)
            // for the same malformed input.
            guard let distance = latticeCaseDistance(c) else { continue }
            // Canonical encoding: one f64 (8-byte LE IEEE-754 bit
            // pattern) per case — harness encoder.writeF64(actual).
            enc.writeF64(distance)
        }

        return CRC32.compute(enc.bytes)
    }

    // MARK: - Per-case distance

    /// Compute the UDC tree distance for one case by reading the `a`
    /// and `b` UDC strings and calling the shipping
    /// SubstrateML.UDCTreeDistance.distance. Returns nil on malformed
    /// input (missing or non-string `a`/`b`), matching the harness
    /// guard that fails the case without encoding bytes.
    private static func latticeCaseDistance(_ c: VectorFile.Case) -> Double? {
        guard case .string(let a) = c.inputs.get("a") ?? .null else { return nil }
        guard case .string(let b) = c.inputs.get("b") ?? .null else { return nil }
        // Shipping UDC tree distance: longest-common-prefix character
        // distance normalized by max length, [0, 1].
        return UDCTreeDistance.distance(a, b)
    }
}
