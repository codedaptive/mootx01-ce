// Lib_tier_contribution.swift
//
// Conformance CRC for the `tier_contribution` primitive computed
// against the SHIPPING substrate library
// (SubstrateML.TierContributionFingerprint), not the glref reference.
// Confirms that the shipping tier-contribution build + canonical
// wire encode produce the exact same conformance byte stream the
// harness produces.
//
// Input schema (mirrors TierContributionPrimitive.validateCase):
//   estate_uuid     : 16-byte hex
//   federation_case : u32 LE hex (1=household, 2=fleet, 3=industry)
//   hlc_packed      : u64 LE hex (the 8-byte packed HLC form)
//   shareable       : array of 32-byte Fingerprint256 hex, LE block order
//
// Per-case work (mirrors validateCase exactly):
//   1. Decode estate_uuid (16 bytes) → UUID.
//   2. Decode federation_case (4 bytes LE) → FederationCase.
//   3. Decode hlc_packed (8 bytes LE) → UInt64 → HLC(packed:).
//   4. Decode each shareable element (32 bytes, 4× LE u64) → Fingerprint256.
//   5. Call SHIPPING TierContributionFingerprint.build(...) — this
//      OR-reduces the cohort fingerprints through the platform kernel
//      and stamps rowCount / aggregate / hlc.
//   6. Call SHIPPING TierContributionFingerprint.encode(...) to get the
//      64-byte canonical wire form (BE-uniform: 16-byte UUID, u32 BE
//      case, u32 BE rowCount, 4× u64 BE aggregate, u64 BE hlc.packed).
//   7. Write those 64 bytes via CanonicalBinaryEncoder.writeBytes.
//
// The concatenated 64-byte-per-case stream is CRC32'd. This matches the
// harness's encodeOutput (which writes the same 64-byte wire_bytes per
// case), so a matching CRC proves the shipping symbol reproduces the
// committed vectors byte-for-byte.

import Foundation
import Harness
import SubstrateTypes
import SubstrateML

enum Lib_tier_contribution {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // estate_uuid: 16 raw bytes.
            guard case .string(let estHex) = c.inputs.get("estate_uuid") ?? .null,
                  let estBytes = try? HexCoding.decode(estHex),
                  estBytes.count == 16 else { continue }

            // federation_case: 4-byte LE u32.
            guard case .string(let fcHex) = c.inputs.get("federation_case") ?? .null,
                  let fcBytes = try? HexCoding.decode(fcHex),
                  fcBytes.count == 4 else { continue }
            let fcRaw = tierU32LE(fcBytes)
            guard let federationCase = FederationCase(rawValue: fcRaw) else { continue }

            // hlc_packed: 8-byte LE u64, fed to the shipping packed init.
            guard case .string(let hlcHex) = c.inputs.get("hlc_packed") ?? .null,
                  let hlcBytes = try? HexCoding.decode(hlcHex),
                  hlcBytes.count == 8 else { continue }
            let hlc = HLC(packed: tierU64LE(hlcBytes))

            // shareable: array of 32-byte LE-block-order Fingerprint256.
            guard case .array(let cohortArr) = c.inputs.get("shareable") ?? .null else { continue }
            var cohort = [Fingerprint256]()
            cohort.reserveCapacity(cohortArr.count)
            var malformed = false
            for v in cohortArr {
                guard case .string(let s) = v,
                      let fp = tierParseFingerprintLE(s) else { malformed = true; break }
                cohort.append(fp)
            }
            if malformed { continue }

            // Shipping build: OR-reduce cohort via the platform kernel,
            // stamp rowCount/aggregate/hlc.
            let contrib = TierContributionFingerprint.build(
                estateUUID: tierUUIDFromBytes(estBytes),
                case: federationCase,
                shareableFingerprints: cohort,
                hlc: hlc)

            // Shipping encode: 64-byte canonical (BE-uniform) wire form.
            let wire = [UInt8](TierContributionFingerprint.encode(contrib))

            // Same per-case write the harness emits.
            enc.writeBytes(wire)
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (tier-prefixed, file-private, unique)

    /// Little-endian u32 from a 4-byte buffer.
    private static func tierU32LE(_ bytes: [UInt8]) -> UInt32 {
        var v: UInt32 = 0
        for j in 0..<4 { v |= UInt32(bytes[j]) << (j * 8) }
        return v
    }

    /// Little-endian u64 from an 8-byte buffer.
    private static func tierU64LE(_ bytes: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for j in 0..<8 { v |= UInt64(bytes[j]) << (j * 8) }
        return v
    }

    /// Build a UUID from 16 raw bytes (in-order).
    private static func tierUUIDFromBytes(_ bytes: [UInt8]) -> UUID {
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    /// Parse a 32-byte hex string as a Fingerprint256 in LE block
    /// order (4 little-endian u64 words). This is the harness's
    /// canonical fingerprint input encoding; it is independent of the
    /// BE-uniform 64-byte wire format the contribution encodes to.
    private static func tierParseFingerprintLE(_ s: String) -> Fingerprint256? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 32 else { return nil }
        var blocks = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blocks[i] = w
        }
        return Fingerprint256(block0: blocks[0], block1: blocks[1],
                              block2: blocks[2], block3: blocks[3])
    }
}
