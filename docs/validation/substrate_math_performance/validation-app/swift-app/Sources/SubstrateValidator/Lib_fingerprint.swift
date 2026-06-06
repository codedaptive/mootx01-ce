// Lib_fingerprint.swift
//
// Lib-side conformance CRC for the `fingerprint` primitive (cookbook
// §3.1). Computes the canonical CRC by calling the SHIPPING lib
// (SubstrateTypes.Fingerprint256), not the glref reference, so the
// validator can report lib-vs-glref drift on the fingerprint wire
// format.
//
// Byte mechanism mirrors Harness FingerprintPrimitive.validateCase
// exactly: decode the four u64 block inputs (16-char LE hex each),
// build the shipping Fingerprint256, then canonical-encode the
// 32-byte `wireBytes` via encoder.writeBytes — one writeBytes call
// per case, in case order. CRC32 over the accumulated bytes must
// equal the committed outputCrc32.
//
// Input schema  : block0..block3, each a 16-char hex string (u64 LE).
// Output schema : wire_bytes, a 32-byte hex string (blocks 0..3 LE).

import Foundation
import Harness
import SubstrateTypes

enum Lib_fingerprint {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            guard case .string(let b0s) = c.inputs.get("block0") ?? .null,
                  case .string(let b1s) = c.inputs.get("block1") ?? .null,
                  case .string(let b2s) = c.inputs.get("block2") ?? .null,
                  case .string(let b3s) = c.inputs.get("block3") ?? .null,
                  let b0 = fpParseU64(b0s),
                  let b1 = fpParseU64(b1s),
                  let b2 = fpParseU64(b2s),
                  let b3 = fpParseU64(b3s)
            else { continue }

            // Shipping API: SubstrateTypes.Fingerprint256.
            //   init(block0:block1:block2:block3:) and the `wireBytes`
            //   property are symbol-identical to glref's — same field
            //   order, same little-endian wire layout (block0 first).
            let fp = Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)

            // Canonical output: the 32-byte wire form, written as a raw
            // byte run — identical to the harness's encoder.writeBytes.
            enc.writeBytes(fp.wireBytes)
        }
        return CRC32.compute(enc.bytes)
    }

    /// Decode a 16-char little-endian hex string into a u64. Mirrors
    /// the harness `parseU64`: 8 bytes, byte i contributes bits
    /// [i*8, i*8+8). Returns nil on wrong length / malformed hex.
    private static func fpParseU64(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (i * 8) }
        return v
    }
}
