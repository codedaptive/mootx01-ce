// TemporalCompressionPrimitive.swift
//
// Temporal compression rollup (cookbook § 8.14). Mirror of
// rust/src/primitives/temporal_compression.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-TemporalCompression.swift
// via the GeniusLocusReference Swift package.
//
// Exercises the `rollup` entry point: given a list of
// lower-level windows, produce a single higher-level window
// whose (start, end, fingerprint, count) reflect the union.
//
// Input schema:
//   target_level : u8 (0=hour, 1=day, 2=week, 3=month, 4=quarter, 5=year)
//   windows      : array of {start_hlc, end_hlc, level, fingerprint, row_count}
//
// Output schema:
//   start_hlc   : 16-byte hex
//   end_hlc     : 16-byte hex
//   level       : u8
//   fingerprint : 32-byte hex
//   row_count   : u32 hex

import Foundation
import GeniusLocusReference

public enum TemporalCompressionPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "temporal_compression",
        cookbookSection: "§8.14",
        referenceFile: "glref-swift-TemporalCompression.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let nWindows = 2 + Int(rng.next() % 6)
            let inputLevelRaw: UInt8 = UInt8(i % 5)
            let inputLevel = WindowLevel(rawValue: Int(inputLevelRaw)) ?? .hour
            let targetLevelRaw: UInt8 = UInt8((Int(inputLevelRaw) + 1) % 6)
            let targetLevel = WindowLevel(rawValue: Int(targetLevelRaw)) ?? .day

            var windows = [TemporalWindow]()
            for _ in 0..<nWindows {
                let startRaw = rng.next()
                let endRaw   = rng.next()
                let fp = Fingerprint256(
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next())
                let rowCount = UInt32(rng.next() & 0xFFFF)

                let startPhys = Int64(startRaw & 0x0000_FFFF_FFFF_FFFF)
                let endPhys   = Int64(endRaw   & 0x0000_FFFF_FFFF_FFFF)
                let startHLC = HLC(physicalTime: startPhys,
                                    logicalCount: 0, nodeID: 0)
                let endHLC   = HLC(physicalTime: endPhys,
                                    logicalCount: 0, nodeID: 0)
                windows.append(TemporalWindow(
                    startHLC: startHLC, endHLC: endHLC,
                    level: inputLevel,
                    fingerprint: fp, rowCount: rowCount))
            }

            let result = TemporalCompression.rollup(
                windows: windows, to: targetLevel)

            let windowsArr: JSONValue = .array(windows.map { w -> JSONValue in
                return .dict(JSONDict([
                    ("start_hlc",   .string(HexCoding.encode(w.startHLC.wireBytes))),
                    ("end_hlc",     .string(HexCoding.encode(w.endHLC.wireBytes))),
                    ("level",       .string(HexCoding.u8(UInt8(w.level.rawValue)))),
                    ("fingerprint", .string(encodeFingerprint(w.fingerprint))),
                    ("row_count",   .string(HexCoding.u32(w.rowCount))),
                ]))
            })

            let inputs = JSONDict([
                ("target_level", .string(HexCoding.u8(targetLevelRaw))),
                ("windows",      windowsArr),
            ])
            let output = JSONDict([
                ("start_hlc",   .string(HexCoding.encode(result.startHLC.wireBytes))),
                ("end_hlc",     .string(HexCoding.encode(result.endHLC.wireBytes))),
                ("level",       .string(HexCoding.u8(UInt8(result.level.rawValue)))),
                ("fingerprint", .string(encodeFingerprint(result.fingerprint))),
                ("row_count",   .string(HexCoding.u32(result.rowCount))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "n=\(nWindows), input_level=\(inputLevelRaw), target=\(targetLevelRaw)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "temporal_compression",
            cookbookSection: "§8.14",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-TemporalCompression.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases { caseResults.append(validateCase(c, encoder: &encoder)) }
        let crcActual = CRC32.compute(encoder.bytes)
        let allPassed = caseResults.allSatisfy { $0.passed }
        return ValidationResult(
            passed: allPassed && crcActual == file.outputCrc32,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual)
    }

    private static func validateCase(_ c: VectorFile.Case,
                                      encoder: inout CanonicalBinaryEncoder)
                                     -> ValidationResult.CaseResult {
        guard case .string(let tlHex) = c.inputs.get("target_level") ?? .null,
              let targetLevelRaw = parseU8(tlHex),
              let targetLevel = WindowLevel(rawValue: Int(targetLevelRaw)) else {
            return fail(c, "missing or malformed target_level")
        }
        guard case .array(let wArr) = c.inputs.get("windows") ?? .null else {
            return fail(c, "missing windows")
        }

        var windows = [TemporalWindow]()
        for v in wArr {
            guard case .dict(let obj) = v,
                  let w = parseWindow(obj) else {
                return fail(c, "malformed window")
            }
            windows.append(w)
        }

        let actual = TemporalCompression.rollup(windows: windows, to: targetLevel)

        guard case .dict(let _) = JSONValue.dict(c.expectedOutput) else {
            return fail(c, "expected_output not dict")
        }
        guard let expected = parseWindow(c.expectedOutput) else {
            return fail(c, "malformed expected window")
        }

        // Encode actual to canonical binary AND compare.
        writeWindow(actual, encoder: &encoder)

        if windowEquals(actual, expected) {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "rollup window mismatch")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard let w = parseWindow(output) else {
            fatalError("expected_output malformed")
        }
        writeWindow(w, encoder: &encoder)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func writeWindow(_ w: TemporalWindow, encoder: inout CanonicalBinaryEncoder) {
        encoder.writeBytes(w.startHLC.wireBytes)
        encoder.writeBytes(w.endHLC.wireBytes)
        encoder.writeU8(UInt8(w.level.rawValue))
        encoder.writeU64(w.fingerprint.block0)
        encoder.writeU64(w.fingerprint.block1)
        encoder.writeU64(w.fingerprint.block2)
        encoder.writeU64(w.fingerprint.block3)
        encoder.writeU32(w.rowCount)
    }

    private static func windowEquals(_ a: TemporalWindow, _ b: TemporalWindow) -> Bool {
        return a.startHLC.physicalTime == b.startHLC.physicalTime
            && a.startHLC.logicalCount == b.startHLC.logicalCount
            && a.startHLC.nodeID == b.startHLC.nodeID
            && a.endHLC.physicalTime == b.endHLC.physicalTime
            && a.endHLC.logicalCount == b.endHLC.logicalCount
            && a.endHLC.nodeID == b.endHLC.nodeID
            && a.level == b.level
            && a.fingerprint.block0 == b.fingerprint.block0
            && a.fingerprint.block1 == b.fingerprint.block1
            && a.fingerprint.block2 == b.fingerprint.block2
            && a.fingerprint.block3 == b.fingerprint.block3
            && a.rowCount == b.rowCount
    }

    private static func parseWindow(_ obj: JSONDict) -> TemporalWindow? {
        guard case .string(let sHex) = obj.get("start_hlc") ?? .null,
              let s = parseHLC(sHex) else { return nil }
        guard case .string(let eHex) = obj.get("end_hlc") ?? .null,
              let e = parseHLC(eHex) else { return nil }
        guard case .string(let lHex) = obj.get("level") ?? .null,
              let lRaw = parseU8(lHex),
              let level = WindowLevel(rawValue: Int(lRaw)) else { return nil }
        guard case .string(let fHex) = obj.get("fingerprint") ?? .null,
              let fp = parseFingerprint(fHex) else { return nil }
        guard case .string(let rcHex) = obj.get("row_count") ?? .null,
              let rc = parseU32(rcHex) else { return nil }
        return TemporalWindow(
            startHLC: s, endHLC: e, level: level,
            fingerprint: fp, rowCount: rc)
    }

    private static func parseHLC(_ s: String) -> HLC? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for i in 0..<8 { phys |= Int64(bytes[i]) << (i * 8) }
        var log: Int32 = 0
        for i in 0..<4 { log  |= Int32(bytes[8 + i]) << (i * 8) }
        var node: Int32 = 0
        for i in 0..<4 { node |= Int32(bytes[12 + i]) << (i * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }

    private static func encodeFingerprint(_ fp: Fingerprint256) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let blocks = [fp.block0, fp.block1, fp.block2, fp.block3]
        for (i, w) in blocks.enumerated() {
            for j in 0..<8 { bytes[i * 8 + j] = UInt8((w >> (j * 8)) & 0xFF) }
        }
        return HexCoding.encode(bytes)
    }

    private static func parseFingerprint(_ s: String) -> Fingerprint256? {
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

    private static func parseU8(_ s: String) -> UInt8? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 1 else { return nil }
        return bytes[0]
    }

    private static func parseU32(_ s: String) -> UInt32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var v: UInt32 = 0
        for (i, b) in bytes.enumerated() { v |= UInt32(b) << (i * 8) }
        return v
    }
}
