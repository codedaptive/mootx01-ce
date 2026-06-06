// Lib_hamming.swift
//
// Conformance CRC for the `hamming` primitive computed against the
// SHIPPING substrate library (packages/libs/*), not the glref
// reference. The harness primitive
// (Harness/Primitives/HammingPrimitive.swift) validates against
// glref's `Hamming.distance`; this validator recomputes the same
// per-case outputs through the shipping `SubstrateTypes.Hamming`
// and serializes them with the IDENTICAL canonical byte stream so
// the resulting CRC32 must match a conformant glref CRC bit for bit.
//
// Input schema mirrors the harness exactly:
//   Pair cases (32):    a, b : Fingerprint256 (32-byte hex, LE),
//                       blocks_bitmask : u8 (bit k => block k).
//   Batched cases (8):  probe : Fingerprint256,
//                       candidates : [Fingerprint256].
//
// Output encoding mirrors HammingPrimitive.validate byte-for-byte:
//   Pair case    -> encoder.writeU32(distance)
//   Batched case -> encoder.writeU32(count); for each: writeU32(distance)
// Cases are walked in file order (pair cases first, then batched),
// matching the generator/validator so the CRC32 is reproducible.
//
// Shipping symbols used:
//   SubstrateTypes.Fingerprint256(block0:block1:block2:block3:)
//   SubstrateTypes.BlockMask(rawValue:)        — bit k => block k
//   SubstrateTypes.Hamming.distance(_:_:blocks:) -> Int
//
// The shipping batched path (SubstrateKernel scalar reference's
// inherited hammingDistanceBatch) is a sequential map of
// hammingDistance256, which equals Hamming.distance(.., blocks:.all)
// per candidate. We therefore compute the batched distances directly
// through Hamming.distance with the all-blocks mask — the
// authoritative scalar value the conformance gate pins.

import Foundation
import Harness
import SubstrateTypes

enum Lib_hamming {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()

        for c in file.cases {
            // Dispatch on schema, exactly as HammingPrimitive.validateCase:
            // a `distances` array marks a batched case; otherwise it is
            // a pair-at-a-time scalar case.
            if case .array(let candArr) = c.inputs.get("candidates") ?? .null {
                encodeBatched(c, candidates: candArr, enc: &enc)
            } else {
                encodePair(c, enc: &enc)
            }
        }

        return CRC32.compute(enc.bytes)
    }

    // MARK: - Pair-at-a-time case

    private static func encodePair(_ c: VectorFile.Case,
                                   enc: inout CanonicalBinaryEncoder) {
        guard case .string(let aHex) = c.inputs.get("a") ?? .null,
              let a = fpHamming(aHex),
              case .string(let bHex) = c.inputs.get("b") ?? .null,
              let b = fpHamming(bHex),
              case .string(let maskHex) = c.inputs.get("blocks_bitmask") ?? .null,
              let mask = u8Hamming(maskHex) else { return }

        // The harness u8 bitmask is bit k => block k, which is exactly
        // BlockMask's rawValue layout (block0=0b0001 ... block3=0b1000).
        let distance = Hamming.distance(a, b, blocks: BlockMask(rawValue: mask))
        enc.writeU32(UInt32(distance))
    }

    // MARK: - Batched case (always all four blocks)

    private static func encodeBatched(_ c: VectorFile.Case,
                                      candidates candArr: [JSONValue],
                                      enc: inout CanonicalBinaryEncoder) {
        guard case .string(let probeHex) = c.inputs.get("probe") ?? .null,
              let probe = fpHamming(probeHex) else { return }

        var distances = [UInt32]()
        distances.reserveCapacity(candArr.count)
        for item in candArr {
            guard case .string(let s) = item, let cand = fpHamming(s) else { return }
            // Batched API always uses all four blocks (no per-call mask).
            distances.append(UInt32(Hamming.distance(probe, cand, blocks: .all)))
        }

        // u32 LE length prefix, then N u32 LE distances — identical to
        // HammingPrimitive.validateBatchedCase.
        enc.writeU32(UInt32(distances.count))
        for v in distances { enc.writeU32(v) }
    }

    // MARK: - Helpers (private, uniquely named to avoid shared-module collisions)

    /// Decode 32-byte LE hex into the shipping Fingerprint256.
    /// Block 0 first; little-endian byte order within each block.
    private static func fpHamming(_ hex: String) -> Fingerprint256? {
        guard let bytes = try? HexCoding.decode(hex), bytes.count == 32 else { return nil }
        var blk = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blk[i] = w
        }
        return Fingerprint256(block0: blk[0], block1: blk[1],
                              block2: blk[2], block3: blk[3])
    }

    /// Decode a single-byte hex string into a UInt8.
    private static func u8Hamming(_ hex: String) -> UInt8? {
        guard let bytes = try? HexCoding.decode(hex), bytes.count == 1 else { return nil }
        return bytes[0]
    }
}
