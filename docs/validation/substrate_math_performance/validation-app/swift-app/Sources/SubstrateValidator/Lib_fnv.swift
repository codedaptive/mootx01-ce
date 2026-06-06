// Lib_fnv.swift
//
// Lib-side conformance CRC for the `fnv` primitive (cookbook §3.3,
// §3.4). Computes the canonical CRC by calling the SHIPPING lib
// (SubstrateTypes.FNV), not the glref reference, so the validator
// can report lib-vs-glref drift on the FNV-1a string-hash family.
//
// Byte mechanism mirrors Harness FNVPrimitive.validateCase exactly:
// per case, dispatch on the `op` byte to one of the three shipping
// entry points, widen the result to u64, and canonical-encode it via
// encoder.writeU64 — one writeU64 call per case, in case order. CRC32
// over the accumulated bytes must equal the committed outputCrc32.
//
// Op semantics (cookbook-defined, identical in lib and glref):
//   op 0  hash64 — FNV-1a 64-bit, the full u64 result.
//   op 1  hash32 — FNV-1a 32-bit, an INDEPENDENT hash family (different
//                  offset basis / prime), zero-extended into the u64.
//   op 2  hash16 — the low-16 fold of hash64 (NOT an FNV-1a 16-bit
//                  variant), zero-extended into the u64.
//
// Input schema  : op, a 1-byte hex string (u8); s, a plain UTF-8
//                 string stored verbatim (NOT hex-encoded — the
//                 shipping API hashes its UTF-8 bytes directly).
// Output schema : result, a 16-char LE hex string (u64). The harness
//                 encodes every op's result as writeU64, so hash32 and
//                 hash16 are zero-extended to 64 bits here too.

import Foundation
import Harness
import SubstrateTypes

enum Lib_fnv {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            guard case .string(let opHex) = c.inputs.get("op") ?? .null,
                  let op = fnvParseU8(opHex),
                  case .string(let s) = c.inputs.get("s") ?? .null
            else { continue }

            // Shipping API: SubstrateTypes.FNV. hash64/hash32/hash16
            // are symbol-identical to glref's FNV — same offset bases,
            // same primes, same UTF-8 byte hashing. Each result is
            // widened to u64 to match the harness's uniform writeU64.
            let result: UInt64
            switch op {
            case 0: result = FNV.hash64(s)
            case 1: result = UInt64(FNV.hash32(s))
            case 2: result = UInt64(FNV.hash16(s))
            default: continue
            }

            // Canonical output: 8 LE bytes per case, identical to the
            // harness's encoder.writeU64(actual).
            enc.writeU64(result)
        }
        return CRC32.compute(enc.bytes)
    }

    /// Parse a `HexCoding.u8`-encoded op byte: an optional `0x` prefix
    /// followed by hex digits. Mirrors the harness `parseU8`. Returns
    /// nil on malformed hex.
    private static func fnvParseU8(_ s: String) -> UInt8? {
        let stripped = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return UInt8(stripped, radix: 16)
    }
}
