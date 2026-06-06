// Lib_info_theory.swift
//
// Lib-side conformance CRC for the `info_theory` primitive (cookbook
// §8.11) — Shannon entropy. Computes the canonical CRC by calling the
// SHIPPING lib SubstrateML.InformationTheory.entropy, not the glref
// reference, so the validator can report lib-vs-glref drift on the
// entropy entry point.
//
// Byte mechanism mirrors Harness InfoTheoryPrimitive.validateCase
// exactly:
//
//   Input schema:
//     probabilities : array of f32 (each an 8-hex-digit IEEE-754
//                     little-endian bit pattern; a probability
//                     distribution that sums to 1.0)
//
//   Output schema:
//     entropy : f32 (Shannon entropy in bits)
//
// For each case we decode the `probabilities` array, call the shipping
// entropy, and write the result with a single encoder.writeF32 —
// identical to the harness, which encodes one f32 per case (the
// IEEE-754 bit pattern of the entropy) and writes nothing for
// malformed cases (`guard ... else { return fail }` writes no canonical
// bytes). f32 is written as its 4-byte little-endian IEEE-754 bit
// pattern by the shared CanonicalBinaryEncoder.writeF32, so the lib
// byte stream is directly comparable to the committed glref CRC.
//
// Note on byte sensitivity: entropy sums pi * log2(pi) over the
// distribution. The transcendental log2 makes the result bit-sensitive,
// so we replicate the harness's exact call (single entropy call over
// the decoded f32 array) and exact encode (one writeF32 per case, in
// case order) to land on the same byte stream.

import Foundation
import Harness
import SubstrateML

enum Lib_info_theory {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases { infoTheoryEncodeCase(c, enc: &enc) }
        return CRC32.compute(enc.bytes)
    }

    /// Decode the `probabilities` array, call the shipping
    /// SubstrateML.InformationTheory.entropy, and write the resulting
    /// entropy as one f32 (4-byte LE IEEE-754 bit pattern). Malformed
    /// input is skipped without writing, mirroring the harness
    /// `guard ... else { return fail }` (failed cases write no canonical
    /// bytes).
    private static func infoTheoryEncodeCase(_ c: VectorFile.Case,
                                             enc: inout CanonicalBinaryEncoder) {
        guard case .array(let arr) = c.inputs.get("probabilities") ?? .null else { return }
        var probs = [Float32]()
        probs.reserveCapacity(arr.count)
        for v in arr {
            guard case .string(let s) = v,
                  let p = infoTheoryParseF32Hex(s) else { return }
            probs.append(p)
        }

        // Shipping API:
        //   SubstrateML.InformationTheory.entropy(_:) -> Float32
        // Same function/signature as the glref reference the harness
        // calls; the only difference is the module it resolves from.
        let h = InformationTheory.entropy(probs)
        enc.writeF32(h)
    }

    /// Decode an 8-char little-endian hex string into a Float32 by its
    /// IEEE-754 bit pattern. Mirrors the harness `parseF32Hex`: 4
    /// bytes, byte i contributes bits [i*8, i*8+8). Returns nil on
    /// wrong length / malformed hex.
    private static func infoTheoryParseF32Hex(_ s: String) -> Float32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt32(b) << (i * 8)
        }
        return Float32(bitPattern: bits)
    }
}
