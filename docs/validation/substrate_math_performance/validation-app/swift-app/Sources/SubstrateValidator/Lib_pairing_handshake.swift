// Lib_pairing_handshake.swift
//
// Lib-side conformance CRC for the `pairing_handshake` primitive
// (cookbook §12.2). Computes the canonical CRC by calling the SHIPPING
// lib (SubstrateML.PairingNonce.seedWith), not the glref reference, so
// the validator can report lib-vs-glref drift on the cross-estate
// pairing-seed derivation hot path.
//
// Byte mechanism mirrors Harness PairingHandshakePrimitive.validateCase
// exactly: per case, decode the three hex inputs, construct the shipping
// PairingNonce, reconstruct both estate UUIDs from raw bytes, derive the
// u64 seed via seedWith, and canonical-encode it via encoder.writeU64 —
// one writeU64 call per case, in case order. CRC32 over the accumulated
// bytes must equal the committed outputCrc32.
//
// The seed derivation FNV-1a-mixes the nonce with the canonical (lower
// under RAW byte order, not uuidString order) estate UUID. The shipping
// PairingNonce.seedWith and glref's are symbol-identical: same byte-wise
// UUID compare, same FNV offset basis / prime. Any disagreement on the
// canonical-ordering rule yields incompatible families and silent
// federation corruption, which this CRC catches.
//
// Input schema:
//   nonce      : 32-byte hex string
//   estate_a   : 16-byte hex string (raw UUID bytes)
//   estate_b   : 16-byte hex string (raw UUID bytes)
//
// Output schema:
//   seed : u64 hex (the derived seed). The harness encodes it as a
//          single writeU64 per case (8 LE bytes), so this does too.

import Foundation
import Harness
import SubstrateML

enum Lib_pairing_handshake {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // Decode the three hex inputs with the same width checks the
            // harness applies: 32-byte nonce, 16-byte UUIDs.
            guard case .string(let nHex) = c.inputs.get("nonce") ?? .null,
                  let nBytes = try? HexCoding.decode(nHex),
                  nBytes.count == 32,
                  case .string(let aHex) = c.inputs.get("estate_a") ?? .null,
                  let aBytes = try? HexCoding.decode(aHex),
                  aBytes.count == 16,
                  case .string(let bHex) = c.inputs.get("estate_b") ?? .null,
                  let bBytes = try? HexCoding.decode(bHex),
                  bBytes.count == 16
            else { continue }

            // Shipping API: SubstrateML.PairingNonce. Fully qualified to
            // avoid colliding with the identically named glref symbol that
            // the harness primitive uses. seedWith reproduces the canonical
            // raw-byte UUID compare and FNV-1a seed mix bit-for-bit.
            let nonce = SubstrateML.PairingNonce(bytes: nBytes)
            let aUUID = pairUUIDFromBytes(aBytes)
            let bUUID = pairUUIDFromBytes(bBytes)
            let seed = nonce.seedWith(estateA: aUUID, estateB: bUUID)

            // Canonical output: 8 LE bytes per case, identical to the
            // harness's encoder.writeU64(actual).
            enc.writeU64(seed)
        }
        return CRC32.compute(enc.bytes)
    }

    /// Build a UUID from 16 raw bytes in declaration order. Mirrors the
    /// harness primitive's `uuidFromBytes`: bytes map straight into the
    /// uuid_t tuple, so seedWith's raw-byte compare sees the same ordering
    /// the test vectors were generated under.
    private static func pairUUIDFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
