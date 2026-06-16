// ShingleSimilarityPrimitive.swift
//
// Character-shingle Jaccard similarity (the substrate-owned recall-
// ranking set primitive). Mirror of rust/src/primitives/shingle_similarity.rs.
//
// Wired to the production reference at
// packages/libs/SubstrateML/Sources/SubstrateML/ShingleSimilarity.swift
// via the SubstrateML package (validated directly, like NMF — the
// production code is the conformance subject).
//
// Determinism: similarity is a pure function of two strings. The value
// is an f32 ratio of two integer set cardinalities, so it is bit-
// identical across Swift and Rust on the same inputs. The only cross-
// port hazard is case folding; the generated test strings are drawn
// from lowercase ASCII letters and spaces ONLY, so `lowercased()`
// (Swift) and `to_lowercase()` (Rust) are both no-ops and the shingle
// sets are byte-identical. The conformance CRC catches any drift.
//
// Input schema:
//   a : string (plain UTF-8, lowercase ASCII + spaces)
//   b : string (plain UTF-8, lowercase ASCII + spaces)
//
// Output schema:
//   similarity : f32 hex (Jaccard over 3-char shingle sets)

import Foundation
import SubstrateML

public enum ShingleSimilarityPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "shingle_similarity",
        cookbookSection: "§8.20",
        referenceFile: "ShingleSimilarity.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Build two strings. Every fourth case shares a prefix so the
            // partial-overlap path is exercised, not only 0.0 / 1.0; the
            // generation is otherwise random word streams.
            let a = randomPhrase(&rng)
            let b: String
            switch i % 4 {
            case 0: b = a                                   // identical -> 1.0
            case 1: b = randomPhrase(&rng)                  // independent
            case 2: b = a + " " + randomPhrase(&rng)        // superset-ish overlap
            default: b = sharePrefix(a, &rng)               // partial overlap
            }

            let s = ShingleSimilarity.similarity(a, b)

            let inputs = JSONDict([
                ("a", .string(a)),
                ("b", .string(b)),
            ])
            let output = JSONDict([
                ("similarity", .string(HexCoding.f32(s))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "|a|=\(a.count), |b|=\(b.count), sim=\(s)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "shingle_similarity",
            cookbookSection: "§8.20",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "ShingleSimilarity.swift"),
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
        guard case .string(let a) = c.inputs.get("a") ?? .null else {
            return fail(c, "missing a")
        }
        guard case .string(let b) = c.inputs.get("b") ?? .null else {
            return fail(c, "missing b")
        }

        let actual = ShingleSimilarity.similarity(a, b)

        guard case .string(let expHex) = c.expectedOutput.get("similarity") ?? .null,
              let expected = parseF32Hex(expHex) else {
            return fail(c, "missing or malformed expected similarity")
        }

        encoder.writeF32(actual)

        if actual.bitPattern == expected.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "similarity mismatch: expected \(HexCoding.f32(expected)), got \(HexCoding.f32(actual))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("similarity") ?? .null,
              let f = parseF32Hex(s) else {
            fatalError("expected_output missing or malformed similarity")
        }
        encoder.writeF32(f)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseF32Hex(_ s: String) -> Float32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt32(b) << (i * 8) }
        return Float32(bitPattern: bits)
    }

    /// 26 lowercase ASCII letters. Case folding is a no-op on these, so
    /// the generated strings are byte-identical between Swift's
    /// `lowercased()` and Rust's `to_lowercase()` — the only cross-port
    /// hazard for this primitive is eliminated by construction.
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    /// A random word of 1–8 lowercase-ASCII letters.
    private static func randomWord(_ rng: inout SplitMix64) -> String {
        let len = 1 + Int(rng.next() % 8)
        var chars = [Character]()
        chars.reserveCapacity(len)
        for _ in 0..<len {
            chars.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
        }
        return String(chars)
    }

    /// A random phrase of 1–5 space-separated words.
    private static func randomPhrase(_ rng: inout SplitMix64) -> String {
        let words = 1 + Int(rng.next() % 5)
        var parts = [String]()
        for _ in 0..<words { parts.append(randomWord(&rng)) }
        return parts.joined(separator: " ")
    }

    /// A new phrase that shares `a`'s first word, then diverges — forces
    /// the partial-overlap (0 < sim < 1) branch.
    private static func sharePrefix(_ a: String, _ rng: inout SplitMix64) -> String {
        let firstWord = a.split(separator: " ").first.map(String.init) ?? "shared"
        return firstWord + " " + randomPhrase(&rng)
    }
}
