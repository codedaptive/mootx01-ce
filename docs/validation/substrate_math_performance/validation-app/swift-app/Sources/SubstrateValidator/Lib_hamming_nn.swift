// Lib_hamming_nn.swift
//
// Lib-side conformance CRC for the `hamming_nn` primitive (cookbook
// §8.2). Computes the canonical CRC by calling the SHIPPING libs
// (SubstrateTypes.Fingerprint256/BlockMask + SubstrateKernel.HammingNN),
// not the glref reference, so the validator can report lib-vs-glref
// drift on the top-K wire encoding.
//
// Byte mechanism mirrors Harness HammingNNPrimitive.validateCase
// exactly (its CRC-accumulation path, not the generator's
// encodeOutput): for each case, decode anchor + blocks_bitmask + k +
// cohort, call the shipping HammingNN.topK, canonicalize the hits by
// (distance ascending, id-bytes ascending), then for each hit emit
// `encoder.writeBytes(idBytes)` (16-byte raw run) followed by
// `encoder.writeU32(distance)`. No length prefix anywhere — hits are
// emitted in canonical order, run after run, case after case. CRC32
// over the accumulated bytes must equal the committed outputCrc32.
//
// Input schema:
//   anchor         : 32-byte hex Fingerprint256 (blocks 0..3 LE).
//   blocks_bitmask : u8 hex (bit k = block k included).
//   k              : u32 hex (LE).
//   cohort         : array of {id: 16-byte hex, fingerprint: 32-byte hex}.
//
// Output (per case, accumulated into the shared encoder):
//   for each canonical hit: writeBytes(16-byte id) then writeU32(distance).
//
// Shipping-vs-glref API note: glref's HammingNN.topK takes a
// `blocks: Set<Int>`; the shipping SubstrateKernel.HammingNN.topK takes
// a `blocks: BlockMask` (an OptionSet over UInt8). The harness's
// `blocks_bitmask` byte IS the BlockMask rawValue (bit k = block k), so
// we construct `BlockMask(rawValue:)` directly rather than going through
// the harness's `bitmaskToBlocks` Set<Int> bridge. The selected-block
// semantics are identical. No kernel instance is needed: HammingNN.topK
// is a free static function (the canonical scalar reference path); the
// kernel-dispatched SIMD/Metal variants are conformance-gated to match
// it bit-for-bit, so the static call yields the canonical result.

import Foundation
import Harness
import SubstrateTypes
import SubstrateKernel

enum Lib_hamming_nn {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // --- anchor: 32-byte LE Fingerprint256 ---
            guard case .string(let aHex) = c.inputs.get("anchor") ?? .null,
                  let anchor = hnnParseFingerprintLE(aHex)
            else { continue }

            // --- blocks_bitmask: single u8, bit k = block k ---
            guard case .string(let bmHex) = c.inputs.get("blocks_bitmask") ?? .null,
                  let bmBytes = try? HexCoding.decode(bmHex), bmBytes.count == 1
            else { continue }
            // The harness byte and BlockMask.rawValue share the same bit
            // layout (block0 = bit0 … block3 = bit3), so this is a direct
            // reinterpret — no Set<Int> bridge needed.
            let blocks = BlockMask(rawValue: bmBytes[0])

            // --- k: u32 little-endian ---
            guard case .string(let kHex) = c.inputs.get("k") ?? .null,
                  let kBytes = try? HexCoding.decode(kHex), kBytes.count == 4
            else { continue }
            var kVal: UInt32 = 0
            for j in 0..<4 { kVal |= UInt32(kBytes[j]) << (j * 8) }
            let k = Int(kVal)
            // HammingNN.topK precondition requires k > 0; an empty/zero-k
            // case cannot conform anyway, so skip rather than trap.
            guard k > 0 else { continue }

            // --- cohort: [{id: 16-byte hex, fingerprint: 32-byte hex}] ---
            guard case .array(let cohortArr) = c.inputs.get("cohort") ?? .null
            else { continue }
            var cohort = [(UUID, Fingerprint256)]()
            var bytesByUUID = [UUID: [UInt8]]()
            var malformed = false
            for v in cohortArr {
                guard case .dict(let obj) = v,
                      case .string(let idHex) = obj.get("id") ?? .null,
                      let idBytes = try? HexCoding.decode(idHex), idBytes.count == 16,
                      case .string(let fpHex) = obj.get("fingerprint") ?? .null,
                      let fp = hnnParseFingerprintLE(fpHex)
                else { malformed = true; break }
                let u = hnnUUIDFromBytes(idBytes)
                cohort.append((u, fp))
                bytesByUUID[u] = idBytes
            }
            if malformed { continue }

            // Shipping top-K, then the harness's canonical (distance asc,
            // id-bytes asc) re-sort. The shipping heap and glref heap may
            // surface equal distances in different orders; the canonical
            // sort below is what makes the output conform across ports.
            let hits = HammingNN.topK(
                anchor: anchor, candidates: cohort, k: k, blocks: blocks)
            let canon = hits.compactMap { hit -> (bytes: [UInt8], distance: UInt32)? in
                guard let b = bytesByUUID[hit.rowID] else { return nil }
                return (b, UInt32(hit.distance))
            }
            .sorted { a, b in
                if a.distance != b.distance { return a.distance < b.distance }
                return hnnLexCompare(a.bytes, b.bytes)
            }

            // Canonical encoding: per hit, 16-byte id run + u32 distance.
            // Exactly the harness validateCase loop — no length prefix.
            for (bytes, d) in canon {
                enc.writeBytes(bytes)
                enc.writeU32(d)
            }
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (private, hnn-prefixed to avoid cross-file collisions)

    /// Decode a 32-byte little-endian Fingerprint256 (blocks 0..3, each a
    /// u64 with byte j contributing bits [j*8, j*8+8)). Mirrors the
    /// harness `parseFingerprintLE`.
    private static func hnnParseFingerprintLE(_ s: String) -> Fingerprint256? {
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

    /// Build a UUID from 16 raw bytes in wire order. Mirrors the harness
    /// `uuidFromBytes`; the byte->UUID map keys the topK result projection.
    private static func hnnUUIDFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    /// Lexicographic byte-array comparison (a < b). Mirrors the harness
    /// `lexCompare`: the canonical secondary sort key when distances tie.
    private static func hnnLexCompare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }
}
