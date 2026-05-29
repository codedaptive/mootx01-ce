// BitwisePrimitive.swift
//
// Fingerprint bitwise arithmetic (cookbook § 8.6). Mirror of
// rust/src/primitives/bitwise.rs. Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-BitwiseArithmetic.swift.
//
// The primitive exercises both `intersect` (AND) and `difference`
// (XOR) on pairs of random fingerprints. Cases alternate between
// the two operations via the `op` field.
//
// Input schema:
//   op : u8 (0 = intersect, 1 = difference)
//   a  : Fingerprint256
//   b  : Fingerprint256
//
// Output schema:
//   result : Fingerprint256

import Foundation
import GeniusLocusReference

public enum BitwisePrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "bitwise",
        cookbookSection: "§8.6",
        referenceFile: "glref-swift-BitwiseArithmetic.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let a = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                    block2: rng.next(), block3: rng.next())
            let b = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                    block2: rng.next(), block3: rng.next())
            let op: UInt8 = UInt8(i % 2)

            let result: Fingerprint256 = (op == 0)
                ? BitwiseArithmetic.intersect(a, b)
                : BitwiseArithmetic.difference(a, b)

            let inputs = JSONDict([
                ("a",  .string(Self.encodeFingerprint(a))),
                ("b",  .string(Self.encodeFingerprint(b))),
                ("op", .string(HexCoding.u8(op))),
            ])
            let output = JSONDict([
                ("result", .string(Self.encodeFingerprint(result))),
            ])

            let opName = (op == 0) ? "intersect" : "difference"
            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "op \(opName)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "bitwise",
            cookbookSection: "§8.6",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-BitwiseArithmetic.swift"),
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
        guard case .string(let aHex) = c.inputs.get("a") ?? .null,
              let a = parseFingerprint(aHex) else { return fail(c, "missing or malformed a") }
        guard case .string(let bHex) = c.inputs.get("b") ?? .null,
              let b = parseFingerprint(bHex) else { return fail(c, "missing or malformed b") }
        guard case .string(let opHex) = c.inputs.get("op") ?? .null,
              let op = parseU8(opHex) else { return fail(c, "missing or malformed op") }

        let actual: Fingerprint256 = (op == 0)
            ? BitwiseArithmetic.intersect(a, b)
            : BitwiseArithmetic.difference(a, b)

        guard case .string(let expHex) = c.expectedOutput.get("result") ?? .null,
              let expected = parseFingerprint(expHex) else {
            return fail(c, "missing or malformed expected result")
        }

        writeFingerprint(actual, encoder: &encoder)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "result mismatch: expected \(encodeFingerprint(expected)), got \(encodeFingerprint(actual))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("result") ?? .null,
              let fp = parseFingerprint(s) else {
            fatalError("expected_output missing or malformed result")
        }
        writeFingerprint(fp, encoder: &encoder)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func writeFingerprint(_ fp: Fingerprint256, encoder: inout CanonicalBinaryEncoder) {
        encoder.writeU64(fp.block0)
        encoder.writeU64(fp.block1)
        encoder.writeU64(fp.block2)
        encoder.writeU64(fp.block3)
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
}
