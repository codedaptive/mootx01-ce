// Lib_partial_state_recall.swift
//
// Lib-side conformance CRC for the `partial_state_recall` primitive
// (cookbook §8.8). Computes the canonical CRC by calling the SHIPPING
// libs (SubstrateTypes.Fingerprint256 + SubstrateML.PartialStateRecall),
// not the glref reference, so the validator can report lib-vs-glref
// drift on the f64 score wire encoding.
//
// Byte mechanism mirrors the Harness PartialStateRecallPrimitive
// CRC-accumulation path exactly. The harness accumulates one f64 per
// case via `encoder.writeF64(score)` — both its generator's
// `encodeOutput` and its `validateCase` paths emit exactly that single
// little-endian f64, no length prefix, case after case. CRC32 over the
// accumulated bytes must equal the committed outputCrc32.
//
// Input schema (per case):
//   row_fingerprint       : 32-byte hex Fingerprint256 (blocks 0..3 LE).
//   anchor                : 32-byte hex Fingerprint256 (blocks 0..3 LE).
//   match_blocks_bitmask  : u8 hex (bit k = block k included in match set).
//   differ_blocks_bitmask : u8 hex (bit k = block k included in differ set).
//
// Output (per case, accumulated into the shared encoder):
//   writeF64(score)  — the f64 partial-match score in [0, 1].
//
// Shipping-vs-glref API note: the shipping SubstrateML.PartialStateRecall.score
// has the identical signature to the glref reference — both take
// `matchBlocks: Set<Int>` and `differBlocks: Set<Int>` and return a
// Double. The harness's `*_blocks_bitmask` byte encodes block membership
// in bits 0..3, so we expand each mask into a Set<Int> (block k present
// iff bit k set), matching the harness's `bitmaskToBlocks` bridge. The
// score math (cookbook §8.8) is byte-identical across ports, so the
// static call yields the canonical f64.

import Foundation
import Harness
import SubstrateTypes
import SubstrateML

enum Lib_partial_state_recall {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // --- row_fingerprint: 32-byte LE Fingerprint256 ---
            guard case .string(let rowHex) = c.inputs.get("row_fingerprint") ?? .null,
                  let row = psrParseFingerprintLE(rowHex)
            else { continue }

            // --- anchor: 32-byte LE Fingerprint256 ---
            guard case .string(let aHex) = c.inputs.get("anchor") ?? .null,
                  let anchor = psrParseFingerprintLE(aHex)
            else { continue }

            // --- match_blocks_bitmask: single u8, bit k = block k ---
            guard case .string(let mHex) = c.inputs.get("match_blocks_bitmask") ?? .null,
                  let mBytes = try? HexCoding.decode(mHex), mBytes.count == 1
            else { continue }

            // --- differ_blocks_bitmask: single u8, bit k = block k ---
            guard case .string(let dHex) = c.inputs.get("differ_blocks_bitmask") ?? .null,
                  let dBytes = try? HexCoding.decode(dHex), dBytes.count == 1
            else { continue }

            // Shipping partial-match score (cookbook §8.8). The Set<Int>
            // expansion (block k present iff bit k set) matches the harness's
            // bitmaskToBlocks bridge so the selected-block semantics are
            // identical across ports.
            let score = PartialStateRecall.score(
                rowFingerprint: row,
                anchor: anchor,
                matchBlocks: psrBitmaskToBlocks(mBytes[0]),
                differBlocks: psrBitmaskToBlocks(dBytes[0]))

            // Canonical encoding: one little-endian f64 per case, exactly the
            // harness CRC-accumulation path — no length prefix.
            enc.writeF64(score)
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (private, psr-prefixed to avoid cross-file collisions)

    /// Decode a 32-byte little-endian Fingerprint256 (blocks 0..3, each a
    /// u64 with byte j contributing bits [j*8, j*8+8)). Mirrors the harness
    /// `parseFingerprint`.
    private static func psrParseFingerprintLE(_ s: String) -> Fingerprint256? {
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

    /// Expand a u8 block bitmask into a Set<Int> (block k present iff bit k
    /// set). Mirrors the harness `bitmaskToBlocks`: the bridge the shipping
    /// PartialStateRecall.score consumes for its match/differ block subsets.
    private static func psrBitmaskToBlocks(_ mask: UInt8) -> Set<Int> {
        var out = Set<Int>()
        for k in 0..<4 where (mask >> UInt8(k)) & 1 == 1 { out.insert(k) }
        return out
    }
}
