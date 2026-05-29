// FingerprintPrimitive.swift
//
// Fingerprint256 wire roundtrip (cookbook § 3.1). Mirror of
// rust/src/primitives/fingerprint.rs. Validates that the
// canonical 32-byte LE wire format roundtrips bit-identically
// through `wireBytes` and `init(wireBytes:)` in both languages.
//
// This primitive guards against any future change to the
// Fingerprint256 wire format that would break federation
// transport or the test-harness JSON encoding for fingerprints.
//
// Input schema:
//   block0..block3 : u64 each (four 16-char hex strings, LE)
//
// Output schema:
//   wire_bytes : 32-byte hex string (lex-sorted blocks 0..3 LE)

import Foundation
import GeniusLocusReference

public enum FingerprintPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "fingerprint",
        cookbookSection: "§3.1",
        referenceFile: "glref-swift-Fingerprint256.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let b0 = rng.next()
            let b1 = rng.next()
            let b2 = rng.next()
            let b3 = rng.next()
            let fp = Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)

            // Forward: encode via wireBytes
            let wire = fp.wireBytes
            // Reverse: decode back; if either path diverges, the
            // case still serializes the original wire bytes so the
            // CRC reflects the canonical truth.
            let roundtripped = (try? Fingerprint256(wireBytes: wire))
                ?? Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
            _ = roundtripped  // exercise both paths; not used in output

            let inputs = JSONDict([
                ("block0", .string(HexCoding.u64(b0))),
                ("block1", .string(HexCoding.u64(b1))),
                ("block2", .string(HexCoding.u64(b2))),
                ("block3", .string(HexCoding.u64(b3))),
            ])
            let output = JSONDict([
                ("wire_bytes", .string(HexCoding.encode(wire))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "random Fingerprint256, roundtrip via wireBytes",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "fingerprint",
            cookbookSection: "§3.1",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-Fingerprint256.swift"),
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
        guard case .string(let b0s) = c.inputs.get("block0") ?? .null,
              let b0 = parseU64(b0s) else { return fail(c, "missing or malformed block0") }
        guard case .string(let b1s) = c.inputs.get("block1") ?? .null,
              let b1 = parseU64(b1s) else { return fail(c, "missing or malformed block1") }
        guard case .string(let b2s) = c.inputs.get("block2") ?? .null,
              let b2 = parseU64(b2s) else { return fail(c, "missing or malformed block2") }
        guard case .string(let b3s) = c.inputs.get("block3") ?? .null,
              let b3 = parseU64(b3s) else { return fail(c, "missing or malformed block3") }

        let fp = Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
        let actualWire = fp.wireBytes
        // Roundtrip check: decode back and verify equality.
        guard let roundtripped = try? Fingerprint256(wireBytes: actualWire),
              roundtripped == fp else {
            return fail(c, "wireBytes roundtrip failed")
        }

        guard case .string(let expWireHex) = c.expectedOutput.get("wire_bytes") ?? .null,
              let expectedWire = try? HexCoding.decode(expWireHex),
              expectedWire.count == 32 else {
            return fail(c, "missing or malformed expected wire_bytes")
        }

        encoder.writeBytes(actualWire)

        if actualWire == expectedWire {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "wire_bytes mismatch: expected \(HexCoding.encode(expectedWire)), got \(HexCoding.encode(actualWire))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("wire_bytes") ?? .null,
              let bytes = try? HexCoding.decode(s),
              bytes.count == 32 else {
            fatalError("expected_output missing or malformed wire_bytes")
        }
        encoder.writeBytes(bytes)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseU64(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (i * 8) }
        return v
    }
}
