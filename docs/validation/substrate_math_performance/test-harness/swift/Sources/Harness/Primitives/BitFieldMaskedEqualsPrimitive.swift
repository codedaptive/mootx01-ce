// BitFieldMaskedEqualsPrimitive.swift
//
// BitField masked-equality predicate (cookbook §2.8 / §7.7).
// F18.2b — promotes the kit-local `andMask` AND+compare pattern
// to a substrate-gated primitive. Mirror of
// rust/src/primitives/bit_field_masked_equals.rs. Wired to the real
// reference at GeniusLocusReference/glref-swift-BitField.swift.
//
// The primitive exercises `BitField.maskedEquals(bitmap, mask:, expected:)`
// across hand-rolled corner cases plus PRNG-driven random Int64
// triples.
//
// Input schema:
//   bitmap   : i64 (hex, u64 bit-pattern encoding)
//   mask     : i64 (hex, u64 bit-pattern encoding)
//   expected : i64 (hex, u64 bit-pattern encoding)
//
// Output schema:
//   result : bool (hex u8, 0x00 = false, 0x01 = true)

import Foundation
import GeniusLocusReference

public enum BitFieldMaskedEqualsPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "bit_field_masked_equals",
        cookbookSection: "§2.8",
        referenceFile: "glref-swift-BitField.swift",
        generate: generate,
        validate: validate
    )

    // Hand-rolled corner triples that exercise the documented edges
    // of the maskedEquals contract. Order is stable and matches
    // rust/src/primitives/bit_field_masked_equals.rs to keep the
    // shared vector deterministic across ports.
    private static let cornerCases: [(bitmap: Int64, mask: Int64, expected: Int64, label: String)] = [
        ( 0,                      0,                      0,                      "all_zero"),
        (-1,                     -1,                     -1,                      "all_ones"),
        ( 0,                      0xFF,                   0x12,                    "zero_bitmap_nonzero_expected"),
        ( 0xFF,                   0,                      0,                       "zero_mask_zero_expected"),
        ( 0xFF,                   0,                      0x42,                    "zero_mask_nonzero_expected"),
        ( 0x12345678,             0xFF00,                 0x5600,                  "post_mask_aligned_match"),
        ( 0x12345678,             0xFF00,                 0x5601,                  "expected_bit_outside_mask"),
        (-1,                      0xF,                    0xF,                     "sign_bit_low_nibble"),
        ( 0x0000_0003_0000_0000,  0x0000_003F_0000_0000,  0x0000_0003_0000_0000,   "cookbook_state_field"),
        ( 0x0000_003F_0000_0000,  0x0000_003F_0000_0000,  0x0000_0003_0000_0000,   "field_full_expected_partial"),
    ]

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let totalCases = 32

        // Hand-rolled corners first.
        for (i, corner) in cornerCases.enumerated() {
            let result = BitField.maskedEquals(corner.bitmap,
                                                mask: corner.mask,
                                                expected: corner.expected)
            cases.append(makeCase(
                index: i,
                bitmap: corner.bitmap,
                mask: corner.mask,
                expected: corner.expected,
                result: result,
                description: "corner: \(corner.label)"))
        }

        // PRNG-driven cases. Alternating "independent" (mostly false)
        // and "aligned" (forces true) keeps the vector mixed.
        let prngCount = totalCases - cornerCases.count
        for j in 0..<prngCount {
            let bitmap = Int64(bitPattern: rng.next())
            let mask = Int64(bitPattern: rng.next())
            let expected: Int64
            if j.isMultiple(of: 2) {
                expected = Int64(bitPattern: rng.next())
            } else {
                expected = bitmap & mask
            }
            let result = BitField.maskedEquals(bitmap, mask: mask, expected: expected)
            cases.append(makeCase(
                index: cornerCases.count + j,
                bitmap: bitmap,
                mask: mask,
                expected: expected,
                result: result,
                description: "prng: \(j.isMultiple(of: 2) ? "independent" : "aligned")"))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "bit_field_masked_equals",
            cookbookSection: "§2.8",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-BitField.swift"),
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
        guard case .string(let bitmapHex) = c.inputs.get("bitmap") ?? .null,
              let bitmap = parseI64(bitmapHex) else { return fail(c, "missing or malformed bitmap") }
        guard case .string(let maskHex) = c.inputs.get("mask") ?? .null,
              let mask = parseI64(maskHex) else { return fail(c, "missing or malformed mask") }
        guard case .string(let expectedHex) = c.inputs.get("expected") ?? .null,
              let expected = parseI64(expectedHex) else { return fail(c, "missing or malformed expected") }

        let actual = BitField.maskedEquals(bitmap, mask: mask, expected: expected)

        guard case .string(let resultHex) = c.expectedOutput.get("result") ?? .null,
              let expectedByte = parseU8(resultHex) else {
            return fail(c, "missing or malformed expected result")
        }
        let expectedResult = (expectedByte != 0)

        encoder.writeU8(actual ? 1 : 0)

        if actual == expectedResult {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "result mismatch: expected \(expectedResult), got \(actual)")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let hex) = output.get("result") ?? .null,
              let byte = parseU8(hex) else {
            fatalError("expected_output missing result")
        }
        encoder.writeU8(byte)
    }

    // MARK: - Helpers

    private static func makeCase(index: Int,
                                  bitmap: Int64,
                                  mask: Int64,
                                  expected: Int64,
                                  result: Bool,
                                  description: String) -> VectorFile.Case {
        let inputs = JSONDict([
            ("bitmap",   .string(HexCoding.u64(UInt64(bitPattern: bitmap)))),
            ("mask",     .string(HexCoding.u64(UInt64(bitPattern: mask)))),
            ("expected", .string(HexCoding.u64(UInt64(bitPattern: expected)))),
        ])
        let output = JSONDict([
            ("result", .string(HexCoding.u8(result ? 1 : 0))),
        ])
        return VectorFile.Case(
            id: String(format: "case_%03d", index),
            description: description,
            inputs: inputs,
            expectedOutput: output)
    }

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseI64(_ s: String) -> Int64? {
        guard let u = parseU64(s) else { return nil }
        return Int64(bitPattern: u)
    }

    private static func parseU64(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[i]) << (i * 8) }
        return v
    }

    private static func parseU8(_ s: String) -> UInt8? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 1 else { return nil }
        return bytes[0]
    }
}
