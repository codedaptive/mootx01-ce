// FNVPrimitive.swift
//
// FNV-1a string hash family (cookbook §3.3, §3.4 — substrate-
// canonical string-to-integer mapping). Mirror of
// rust/src/primitives/fnv.rs. Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-FNV.swift.
//
// The primitive exercises all three FNV-1a entry points the
// substrate exports: hash64, hash32, and the 16-bit fold.
// Cases cycle through the three ops via the `op` field.
//
// Input schema:
//   op : u8 (0 = hash64, 1 = hash32, 2 = hash16)
//   s  : utf-8 string (canonical case lit)
//
// Output schema:
//   result : u64 (hex, zero-extended for hash32 / hash16)

import Foundation
import GeniusLocusReference

public enum FNVPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "fnv",
        cookbookSection: "§3.3",
        referenceFile: "glref-swift-FNV.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let op = UInt8(i % 3)
            let s = randomString(&rng, length: 1 + Int(rng.next() % 24))

            let result: UInt64
            switch op {
            case 0: result = FNV.hash64(s)
            case 1: result = UInt64(FNV.hash32(s))
            default: result = UInt64(FNV.hash16(s))
            }

            let inputs = JSONDict([
                ("op", .string(HexCoding.u8(op))),
                ("s",  .string(s)),
            ])
            let output = JSONDict([
                ("result", .string(HexCoding.u64(result))),
            ])

            let opName = (op == 0) ? "hash64" : (op == 1 ? "hash32" : "hash16")
            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "op \(opName), len \(s.utf8.count)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "fnv",
            cookbookSection: "§3.3",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-FNV.swift"),
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
        guard case .string(let opHex) = c.inputs.get("op") ?? .null,
              let op = parseU8(opHex) else { return fail(c, "missing or malformed op") }
        guard case .string(let s) = c.inputs.get("s") ?? .null else {
            return fail(c, "missing or malformed s")
        }

        let actual: UInt64
        switch op {
        case 0: actual = FNV.hash64(s)
        case 1: actual = UInt64(FNV.hash32(s))
        case 2: actual = UInt64(FNV.hash16(s))
        default: return fail(c, "unknown op \(op)")
        }

        guard case .string(let expectedHex) = c.expectedOutput.get("result") ?? .null,
              let expected = parseU64(expectedHex) else {
            return fail(c, "missing or malformed expected result")
        }

        encoder.writeU64(actual)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "result mismatch: expected \(String(expected, radix: 16)), got \(String(actual, radix: 16))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let hex) = output.get("result") ?? .null,
              let raw = parseU64(hex) else {
            fatalError("expected_output missing result")
        }
        encoder.writeU64(raw)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    /// Build a deterministic string from the RNG. Uses a safe
    /// printable-ASCII alphabet so JSON serialization is lossless
    /// and both languages produce identical UTF-8 byte streams.
    private static func randomString(_ rng: inout SplitMix64, length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for _ in 0..<length {
            let r = rng.next()
            bytes.append(alphabet[Int(r % UInt64(alphabet.count))])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseU8(_ s: String) -> UInt8? {
        let stripped = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return UInt8(stripped, radix: 16)
    }

    /// Parse a `HexCoding.u64`-encoded string: 16 hex chars
    /// representing 8 LE bytes (byte 0 = LSB).
    private static func parseU64(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[i]) << (i * 8) }
        return v
    }
}
