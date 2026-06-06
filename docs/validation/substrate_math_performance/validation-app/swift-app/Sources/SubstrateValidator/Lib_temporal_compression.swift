// Lib_temporal_compression.swift
//
// Lib-side conformance CRC for the `temporal_compression` primitive
// (cookbook §8.14). Computes the canonical CRC by calling the
// SHIPPING libs — SubstrateML.TemporalCompression.rollup over
// SubstrateTypes' TemporalWindow / WindowLevel / Fingerprint256 /
// HLC — not the glref reference, so the validator can report
// lib-vs-glref drift on temporal rollups.
//
// Byte mechanism mirrors Harness TemporalCompressionPrimitive
// (encodeOutput / writeWindow) exactly. Each case carries:
//
//   inputs.target_level : u8 hex (1 byte) — coarser level to roll up to
//   inputs.windows      : .array of {
//                            start_hlc:   HLC-32hex (16 wire bytes),
//                            end_hlc:     HLC-32hex (16 wire bytes),
//                            level:       u8 hex (1 byte),
//                            fingerprint: Fingerprint256-64hex (32 bytes),
//                            row_count:   u32 hex (4 bytes) }
//   expected_output     : a single rolled-up TemporalWindow with the
//                         same five fields as a window.
//
// For each case we decode the input windows, call the SHIPPING
// SubstrateML.TemporalCompression.rollup(windows:to:), and write the
// resulting window. rollup OR-reduces the input fingerprints, sums
// row counts, and takes (minStart, maxEnd) over the inputs — the
// operation is associative/commutative so input order does not change
// the result. Empty input yields TemporalWindow.empty(level:) (zero
// HLCs, zero fingerprint, zero rows), matching glref.
//
// Output encoding per window (byte-for-byte identical to the harness
// `writeWindow`, no length prefix):
//   startHLC.wireBytes  — 16 LE bytes (8 phys + 4 log + 4 node)
//   endHLC.wireBytes    — 16 LE bytes
//   writeU8(level.rawValue)
//   writeU64(fingerprint.block0)         — 4× writeU64 LE in block order;
//   writeU64(fingerprint.block1)           equivalent to the 32 LE bytes
//   writeU64(fingerprint.block2)           of Fingerprint256.wireBytes.
//   writeU64(fingerprint.block3)
//   writeU32(rowCount)
//
// Glref-vs-shipping diff: the harness drives the glref reference via
// the GeniusLocusReference package (glref-swift-TemporalCompression),
// while this file calls the shipping SubstrateML symbol of the same
// name and signature. The TemporalWindow / WindowLevel / HLC /
// Fingerprint256 shapes and the rollup contract are identical across
// the two ports, so the canonical bytes match.

import Foundation
import Harness
import SubstrateTypes
import SubstrateML

enum Lib_temporal_compression {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            tcEncodeCase(c, enc: &enc)
        }
        return CRC32.compute(enc.bytes)
    }

    /// Decode one case's target level + windows, run the shipping
    /// TemporalCompression.rollup, and write the resulting window.
    /// On malformed input we skip without writing, mirroring the
    /// harness `guard ... else { return fail }` (failed cases emit
    /// no canonical bytes).
    private static func tcEncodeCase(_ c: VectorFile.Case,
                                     enc: inout CanonicalBinaryEncoder) {
        guard case .string(let tlHex) = c.inputs.get("target_level") ?? .null,
              let targetLevelRaw = tcParseU8(tlHex),
              let targetLevel = WindowLevel(rawValue: Int(targetLevelRaw)) else { return }

        guard case .array(let wArr) = c.inputs.get("windows") ?? .null else { return }
        var windows = [TemporalWindow]()
        windows.reserveCapacity(wArr.count)
        for v in wArr {
            guard case .dict(let obj) = v,
                  let w = tcParseWindow(obj) else { return }
            windows.append(w)
        }

        // Shipping API: SubstrateML.TemporalCompression.rollup over
        // [TemporalWindow] to the coarser target level. OR-reduces the
        // fingerprints, sums rowCount, takes min start / max end HLC.
        let result = TemporalCompression.rollup(windows: windows, to: targetLevel)
        tcWriteWindow(result, enc: &enc)
    }

    /// Write a TemporalWindow in the harness `writeWindow` order:
    /// startHLC wire bytes, endHLC wire bytes, level u8, fingerprint
    /// as four LE u64 blocks, rowCount u32. No length prefix.
    private static func tcWriteWindow(_ w: TemporalWindow,
                                      enc: inout CanonicalBinaryEncoder) {
        enc.writeBytes(w.startHLC.wireBytes)
        enc.writeBytes(w.endHLC.wireBytes)
        enc.writeU8(UInt8(w.level.rawValue))
        enc.writeU64(w.fingerprint.block0)
        enc.writeU64(w.fingerprint.block1)
        enc.writeU64(w.fingerprint.block2)
        enc.writeU64(w.fingerprint.block3)
        enc.writeU32(w.rowCount)
    }

    /// Decode a window dict {start_hlc, end_hlc, level, fingerprint,
    /// row_count} into a TemporalWindow. Mirrors the harness
    /// `parseWindow`; returns nil on any malformed / missing field.
    private static func tcParseWindow(_ obj: JSONDict) -> TemporalWindow? {
        guard case .string(let sHex) = obj.get("start_hlc") ?? .null,
              let s = tcParseHLC(sHex) else { return nil }
        guard case .string(let eHex) = obj.get("end_hlc") ?? .null,
              let e = tcParseHLC(eHex) else { return nil }
        guard case .string(let lHex) = obj.get("level") ?? .null,
              let lRaw = tcParseU8(lHex),
              let level = WindowLevel(rawValue: Int(lRaw)) else { return nil }
        guard case .string(let fHex) = obj.get("fingerprint") ?? .null,
              let fp = tcParseFingerprint(fHex) else { return nil }
        guard case .string(let rcHex) = obj.get("row_count") ?? .null,
              let rc = tcParseU32(rcHex) else { return nil }
        return TemporalWindow(startHLC: s, endHLC: e, level: level,
                              fingerprint: fp, rowCount: rc)
    }

    /// Decode a 32-char (16-byte) hex string into an HLC. Mirrors the
    /// harness `parseHLC`: physicalTime from bytes [0,8) LE,
    /// logicalCount from [8,12) LE, nodeID from [12,16) LE. Returns
    /// nil on wrong length / malformed hex.
    private static func tcParseHLC(_ s: String) -> HLC? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for i in 0..<8 { phys |= Int64(bytes[i]) << (i * 8) }
        var log: Int32 = 0
        for i in 0..<4 { log |= Int32(bytes[8 + i]) << (i * 8) }
        var node: Int32 = 0
        for i in 0..<4 { node |= Int32(bytes[12 + i]) << (i * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }

    /// Decode a 64-char little-endian hex string into a Fingerprint256.
    /// Mirrors the harness `parseFingerprint`: 32 bytes, block i built
    /// from bytes [i*8, i*8+8) little-endian. Returns nil on wrong
    /// length / malformed hex.
    private static func tcParseFingerprint(_ s: String) -> Fingerprint256? {
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

    /// Decode a 1-byte hex string into a UInt8. Returns nil on wrong
    /// length / malformed hex.
    private static func tcParseU8(_ s: String) -> UInt8? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 1 else { return nil }
        return bytes[0]
    }

    /// Decode a 4-byte little-endian hex string into a UInt32. Returns
    /// nil on wrong length / malformed hex.
    private static func tcParseU32(_ s: String) -> UInt32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var v: UInt32 = 0
        for (i, b) in bytes.enumerated() { v |= UInt32(b) << (i * 8) }
        return v
    }
}
