// JaccardPrimitive.swift
//
// Jaccard similarity/distance over 256-bit fingerprints (cookbook
// §8.21, W2.5 Track M1 activation). Mirror of
// rust/src/primitives/jaccard.rs.
//
// Wired to the PRODUCTION reference at
// packages/libs/SubstrateTypes/Sources/SubstrateTypes/Jaccard.swift
// via the SubstrateTypes package (validated directly, like
// shingle_similarity and NMF — the production code is the
// conformance subject).
//
// Determinism: similarity = popcount(a AND b) / popcount(a OR b).
// Both popcounts are exact small integers; the single f64 division
// of exact integers is IEEE-754-identical across ports, so outputs
// are gated on bit-pattern equality (f64 hex), not tolerance.
//
// Empty-union convention (pinned by case_032/case_033): both-empty
// or either-empty-versus-anything unions of zero yield similarity
// 0.0, NEVER 1.0 — an all-zero fingerprint carries no evidence and
// must not read as a perfect match in a retrieval lane.
//
// Input schema (34 cases):
//   a : Fingerprint256 (32-byte hex, LE — same encoding as hamming)
//   b : Fingerprint256
//
// Case construction cycles i % 4 over the 32 seeded cases:
//   0 : independent random pair          (typical partial overlap)
//   1 : b = a                            (identical -> 1.0)
//   2 : b = complement of a              (disjoint -> 0.0)
//   3 : b = a AND random mask            (subset partial overlap)
// plus two fixed edge cases: case_032 both-zero, case_033 zero vs
// random (both -> 0.0 by the empty-union convention).
//
// Output schema:
//   similarity : f64 hex (IEEE-754 bit pattern, LE)
//   distance   : f64 hex (1 - similarity)

import Foundation
import SubstrateTypes

public enum JaccardPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "jaccard",
        cookbookSection: "§8.21",
        referenceFile: "Jaccard.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let seededCount = 32

        for i in 0..<seededCount {
            let a = SubstrateTypes.Fingerprint256(
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next())
            let b: SubstrateTypes.Fingerprint256
            switch i % 4 {
            case 0:
                b = SubstrateTypes.Fingerprint256(
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next())
            case 1:
                b = a
            case 2:
                // Complement: intersection with a is empty, union is all
                // 256 bits -> similarity exactly 0.0.
                b = SubstrateTypes.Fingerprint256(
                    block0: ~a.block0, block1: ~a.block1,
                    block2: ~a.block2, block3: ~a.block3)
            default:
                // Subset of a: intersection == b, union == a -> similarity
                // popcount(b)/popcount(a), a genuine interior value.
                b = SubstrateTypes.Fingerprint256(
                    block0: a.block0 & rng.next(), block1: a.block1 & rng.next(),
                    block2: a.block2 & rng.next(), block3: a.block3 & rng.next())
            }
            cases.append(makeCase(index: i, a: a, b: b))
        }

        // Fixed edge cases pinning the empty-union convention.
        cases.append(makeCase(index: seededCount,
                              a: SubstrateTypes.Fingerprint256.zero,
                              b: SubstrateTypes.Fingerprint256.zero))
        cases.append(makeCase(index: seededCount + 1,
                              a: SubstrateTypes.Fingerprint256.zero,
                              b: SubstrateTypes.Fingerprint256(
                                  block0: rng.next(), block1: rng.next(),
                                  block2: rng.next(), block3: rng.next())))

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "jaccard",
            cookbookSection: "§8.21",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "Jaccard.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    private static func makeCase(index: Int,
                                 a: SubstrateTypes.Fingerprint256,
                                 b: SubstrateTypes.Fingerprint256) -> VectorFile.Case {
        let similarity = Jaccard.similarity(a, b)
        let distance = Jaccard.distance(a, b)
        let inputs = JSONDict([
            ("a", .string(encodeFingerprint(a))),
            ("b", .string(encodeFingerprint(b))),
        ])
        let output = JSONDict([
            ("similarity", .string(HexCoding.f64(similarity))),
            ("distance",   .string(HexCoding.f64(distance))),
        ])
        return VectorFile.Case(
            id: String(format: "case_%03d", index),
            description: "similarity \(similarity)",
            inputs: inputs, expectedOutput: output)
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

        let actualSimilarity = Jaccard.similarity(a, b)
        let actualDistance = Jaccard.distance(a, b)

        guard case .string(let simHex) = c.expectedOutput.get("similarity") ?? .null,
              let expectedSimilarity = parseF64Hex(simHex) else {
            return fail(c, "missing or malformed expected similarity")
        }
        guard case .string(let distHex) = c.expectedOutput.get("distance") ?? .null,
              let expectedDistance = parseF64Hex(distHex) else {
            return fail(c, "missing or malformed expected distance")
        }

        encoder.writeF64(actualSimilarity)
        encoder.writeF64(actualDistance)

        if actualSimilarity.bitPattern == expectedSimilarity.bitPattern
            && actualDistance.bitPattern == expectedDistance.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        }
        return ValidationResult.CaseResult(
            id: c.id, passed: false,
            diagnostic: "mismatch: expected sim \(HexCoding.f64(expectedSimilarity)) "
                + "dist \(HexCoding.f64(expectedDistance)), got sim "
                + "\(HexCoding.f64(actualSimilarity)) dist \(HexCoding.f64(actualDistance))")
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        // Order MUST match validateCase (similarity then distance) so
        // generator and validator produce identical canonical byte streams.
        guard case .string(let simHex) = output.get("similarity") ?? .null,
              let s = parseF64Hex(simHex),
              case .string(let distHex) = output.get("distance") ?? .null,
              let d = parseF64Hex(distHex) else {
            fatalError("expected_output missing or malformed similarity/distance")
        }
        encoder.writeF64(s)
        encoder.writeF64(d)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    /// Hex-encode a Fingerprint256 as 64 lowercase chars (32 bytes LE) —
    /// the same encoding hamming uses, so JSON strings are byte-identical
    /// across languages.
    private static func encodeFingerprint(_ fp: SubstrateTypes.Fingerprint256) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let blocks = [fp.block0, fp.block1, fp.block2, fp.block3]
        for (i, w) in blocks.enumerated() {
            for j in 0..<8 { bytes[i * 8 + j] = UInt8((w >> (j * 8)) & 0xFF) }
        }
        return HexCoding.encode(bytes)
    }

    private static func parseFingerprint(_ s: String) -> SubstrateTypes.Fingerprint256? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 32 else { return nil }
        var blocks = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blocks[i] = w
        }
        return SubstrateTypes.Fingerprint256(
            block0: blocks[0], block1: blocks[1],
            block2: blocks[2], block3: blocks[3])
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }
}
