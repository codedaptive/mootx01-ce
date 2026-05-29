// PartialStateRecallPrimitive.swift
//
// Partial-state recall scoring (cookbook § 8.8). Mirror of
// rust/src/primitives/partial_state_recall.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-PartialStateRecall.swift
// via the GeniusLocusReference Swift package.
//
// Exercises the `score` entry point: given a row fingerprint, an
// anchor fingerprint, and bitmask-encoded match/differ block
// sets, compute the f64 recall score. Both ports must produce
// bit-identical f64 outputs.
//
// Input schema:
//   row_fingerprint      : Fingerprint256
//   anchor               : Fingerprint256
//   match_blocks_bitmask : u8 (bit k = block k included in match set)
//   differ_blocks_bitmask: u8 (bit k = block k included in differ set)
//
// Output schema:
//   score : f64

import Foundation
import GeniusLocusReference

public enum PartialStateRecallPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "partial_state_recall",
        cookbookSection: "§8.8",
        referenceFile: "glref-swift-PartialStateRecall.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let row = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                      block2: rng.next(), block3: rng.next())
            let anchor = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                         block2: rng.next(), block3: rng.next())

            // Cycle match/differ partitions. Both ports require
            // non-empty match and differ sets for a non-zero score;
            // cycles pick block partitions that satisfy both.
            let (mMask, dMask): (UInt8, UInt8) = [
                (0x3, 0xC),  // {0,1} vs {2,3}
                (0x5, 0xA),  // {0,2} vs {1,3}
                (0x9, 0x6),  // {0,3} vs {1,2}
                (0x1, 0xE),  // {0}   vs {1,2,3}
            ][i % 4]

            let matchSet = bitmaskToBlocks(mMask)
            let differSet = bitmaskToBlocks(dMask)
            let score = PartialStateRecall.score(
                rowFingerprint: row, anchor: anchor,
                matchBlocks: matchSet, differBlocks: differSet)

            let inputs = JSONDict([
                ("row_fingerprint",       .string(encodeFingerprint(row))),
                ("anchor",                .string(encodeFingerprint(anchor))),
                ("match_blocks_bitmask",  .string(HexCoding.u8(mMask))),
                ("differ_blocks_bitmask", .string(HexCoding.u8(dMask))),
            ])
            let output = JSONDict([
                ("score", .string(HexCoding.f64(score))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: String(format:
                    "match=0x%01X, differ=0x%01X, score=%.6f", mMask, dMask, score),
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "partial_state_recall",
            cookbookSection: "§8.8",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-PartialStateRecall.swift"),
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
        guard case .string(let rowHex) = c.inputs.get("row_fingerprint") ?? .null,
              let row = parseFingerprint(rowHex) else {
            return fail(c, "missing or malformed row_fingerprint")
        }
        guard case .string(let aHex) = c.inputs.get("anchor") ?? .null,
              let anchor = parseFingerprint(aHex) else {
            return fail(c, "missing or malformed anchor")
        }
        guard case .string(let mHex) = c.inputs.get("match_blocks_bitmask") ?? .null,
              let mMask = parseU8(mHex) else {
            return fail(c, "missing or malformed match_blocks_bitmask")
        }
        guard case .string(let dHex) = c.inputs.get("differ_blocks_bitmask") ?? .null,
              let dMask = parseU8(dHex) else {
            return fail(c, "missing or malformed differ_blocks_bitmask")
        }

        let actual = PartialStateRecall.score(
            rowFingerprint: row, anchor: anchor,
            matchBlocks: bitmaskToBlocks(mMask),
            differBlocks: bitmaskToBlocks(dMask))

        guard case .string(let expHex) = c.expectedOutput.get("score") ?? .null,
              let expected = parseF64Hex(expHex) else {
            return fail(c, "missing or malformed expected score")
        }

        encoder.writeF64(actual)

        if actual.bitPattern == expected.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "score mismatch: expected \(HexCoding.f64(expected)), got \(HexCoding.f64(actual))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("score") ?? .null,
              let f = parseF64Hex(s) else {
            fatalError("expected_output missing or malformed score")
        }
        encoder.writeF64(f)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func bitmaskToBlocks(_ mask: UInt8) -> Set<Int> {
        var out = Set<Int>()
        for k in 0..<4 where (mask >> UInt8(k)) & 1 == 1 { out.insert(k) }
        return out
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

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }
}
