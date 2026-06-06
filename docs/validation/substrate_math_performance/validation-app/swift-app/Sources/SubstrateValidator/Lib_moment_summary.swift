// Lib_moment_summary.swift
//
// Lib-side conformance CRC for the `moment_summary` primitive
// (cookbook §8.7). Computes the canonical CRC by calling the
// SHIPPING libs — SubstrateML.MomentSummary over SubstrateTypes'
// RowLite / TimeRange / Fingerprint256 / HLC — not the glref
// reference, so the validator can report lib-vs-glref drift on
// moment-summary fingerprints.
//
// Byte mechanism mirrors Harness MomentSummaryPrimitive.validateCase
// exactly. Each case carries:
//
//   inputs.rows   : .array of {capture_hlc: HLC-32hex (16 wire bytes),
//                              fingerprint: Fingerprint256-64hex (32 bytes)}
//   inputs.window : {end: HLC-32hex, start: HLC-32hex}
//   expected_output.summary : Fingerprint256 (64-hex, 32 wire bytes)
//
// For each case we decode the rows into [RowLite] (each pairing the
// fingerprint with its capture HLC), build the TimeRange window, and
// call the SHIPPING SubstrateML.MomentSummary.summarize([RowLite],
// window:, activeDuring:) with the captured-during predicate. The
// result is one Fingerprint256, written as 4× writeU64 LE in
// block0..block3 order — identical to the harness's encodeOutput /
// validateCase (`encoder.writeBytes(actual.wireBytes)` is the same
// 32 LE bytes as four writeU64 in block order).
//
// Glref-vs-shipping API asymmetry (bridged here, byte-identical
// output): the harness drives the glref `Row` overload of summarize
// and resolves each row's capture HLC through an index-counter
// closure walking a parallel HLC array in row order. The shipping
// libs expose a lightweight `RowLite` (fingerprint + captureHLC) and
// a matching summarize overload, so the capture HLC travels with the
// row and the predicate is the stock `MomentSummary.capturedDuring`.
// Both paths OR-reduce the fingerprints of rows whose capture HLC
// lies in [start, end], consuming rows in JSON-array order, so the
// OR accumulates in identical order and the canonical bytes match.

import Foundation
import Harness
import SubstrateTypes
import SubstrateML

enum Lib_moment_summary {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            momentSummaryEncodeCase(c, enc: &enc)
        }
        return CRC32.compute(enc.bytes)
    }

    /// Decode one case's rows + window, run the shipping
    /// MomentSummary.summarize, and write the result fingerprint.
    /// On malformed input we skip without writing, mirroring the
    /// harness `guard ... else { return fail }` (failed cases emit
    /// no canonical bytes).
    private static func momentSummaryEncodeCase(_ c: VectorFile.Case,
                                                enc: inout CanonicalBinaryEncoder) {
        guard case .array(let rowsArr) = c.inputs.get("rows") ?? .null else { return }
        var rows = [RowLite]()
        rows.reserveCapacity(rowsArr.count)
        for rv in rowsArr {
            guard case .dict(let rd) = rv else { return }
            guard case .string(let fpHex) = rd.get("fingerprint") ?? .null,
                  let fp = momentSummaryParseFingerprint(fpHex) else { return }
            guard case .string(let hHex) = rd.get("capture_hlc") ?? .null,
                  let hlc = momentSummaryParseHLC(hHex) else { return }
            rows.append(RowLite(fingerprint: fp, captureHLC: hlc))
        }

        guard case .dict(let wd) = c.inputs.get("window") ?? .null else { return }
        guard case .string(let startHex) = wd.get("start") ?? .null,
              let start = momentSummaryParseHLC(startHex) else { return }
        guard case .string(let endHex) = wd.get("end") ?? .null,
              let end = momentSummaryParseHLC(endHex) else { return }
        let window = TimeRange(start: start, end: end)

        // Shipping API: SubstrateML.MomentSummary.summarize over
        // [RowLite] with the captured-during predicate. Empty / all-
        // excluded inputs OR-reduce to Fingerprint256.zero (identity),
        // symbol-equivalent to glref. RowLite already carries the
        // capture HLC, so no index-counter closure is needed.
        let summary = MomentSummary.summarize(rows: rows, window: window,
                                              activeDuring: MomentSummary.capturedDuring)
        momentSummaryWriteFingerprint(summary, enc: &enc)
    }

    /// Write a Fingerprint256 as four little-endian u64 blocks, in
    /// block0..block3 order — identical to the harness writeBytes of
    /// `wireBytes` (32 LE bytes == four writeU64 in block order).
    private static func momentSummaryWriteFingerprint(_ fp: Fingerprint256,
                                                      enc: inout CanonicalBinaryEncoder) {
        enc.writeU64(fp.block0)
        enc.writeU64(fp.block1)
        enc.writeU64(fp.block2)
        enc.writeU64(fp.block3)
    }

    /// Decode a 64-char little-endian hex string into a Fingerprint256.
    /// Mirrors the harness `parseFingerprint`: 32 bytes, block i built
    /// from bytes [i*8, i*8+8) little-endian. Returns nil on wrong
    /// length / malformed hex.
    private static func momentSummaryParseFingerprint(_ s: String) -> Fingerprint256? {
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

    /// Decode a 32-char (16-byte) hex string into an HLC. Mirrors the
    /// harness `parseHLC`: physicalTime from bytes [0,8) LE,
    /// logicalCount from [8,12) LE, nodeID from [12,16) LE. Returns
    /// nil on wrong length / malformed hex.
    private static func momentSummaryParseHLC(_ s: String) -> HLC? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for i in 0..<8 { phys |= Int64(bytes[i]) << (i * 8) }
        var log: Int32 = 0
        for i in 0..<4 { log |= Int32(bytes[8 + i]) << (i * 8) }
        var node: Int32 = 0
        for i in 0..<4 { node |= Int32(bytes[12 + i]) << (i * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }
}
