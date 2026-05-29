// InfoTheoryPrimitive.swift
//
// Information theory (cookbook § 8.11), entropy entry point.
// Mirror of rust/src/primitives/info_theory.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-InformationTheory.swift
// via the GeniusLocusReference Swift package.
//
// This primitive exercises the Shannon entropy entry point. The
// full InformationTheory API also covers mutualInformation,
// klDivergence, crossEntropy, jensenShannon, and
// normalizedMutualInformation; those will land as additional
// primitives in a future pass (each is a similar shape but with a
// different input cardinality - pair, joint matrix, etc).
//
// Input schema:
//   probabilities : array of f32 (probability distribution; must sum to 1.0)
//
// Output schema:
//   entropy : f32 (Shannon entropy in bits)

import Foundation
import GeniusLocusReference

public enum InfoTheoryPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "info_theory",
        cookbookSection: "§8.11",
        referenceFile: "glref-swift-InformationTheory.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Cardinality cycles through {2, 4, 8, 16}.
            let k = 1 << ((i % 4) + 1)
            let probs = randomProbabilityDistribution(&rng, k: k)
            let h = InformationTheory.entropy(probs)

            let probsArr: JSONValue = .array(probs.map { .string(HexCoding.f32($0)) })
            let inputs = JSONDict([
                ("probabilities", probsArr),
            ])
            let output = JSONDict([
                ("entropy", .string(HexCoding.f32(h))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "cardinality \(k), entropy \(h)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "info_theory",
            cookbookSection: "§8.11",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-InformationTheory.swift"),
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
        guard case .array(let arr) = c.inputs.get("probabilities") ?? .null else {
            return fail(c, "missing probabilities")
        }
        var probs = [Float32]()
        for v in arr {
            guard case .string(let s) = v, let p = parseF32Hex(s) else {
                return fail(c, "malformed probability element")
            }
            probs.append(p)
        }

        let actual = InformationTheory.entropy(probs)

        guard case .string(let expHex) = c.expectedOutput.get("entropy") ?? .null,
              let expected = parseF32Hex(expHex) else {
            return fail(c, "missing or malformed expected entropy")
        }

        encoder.writeF32(actual)

        if actual.bitPattern == expected.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "entropy mismatch: expected \(HexCoding.f32(expected)), got \(HexCoding.f32(actual))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("entropy") ?? .null,
              let f = parseF32Hex(s) else {
            fatalError("expected_output missing or malformed entropy")
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

    /// Build a probability distribution of length k that sums to
    /// exactly 1.0 in f32. Method: draw k raw weights from the
    /// RNG, normalize by their sum. Both languages must produce
    /// the same f32 values from the same RNG state.
    private static func randomProbabilityDistribution(_ rng: inout SplitMix64, k: Int) -> [Float32] {
        var weights = [Float32]()
        weights.reserveCapacity(k)
        var total: Float32 = 0
        for _ in 0..<k {
            let raw = rng.next()
            let w = Float32(raw >> 40) / Float32(1 << 24)   // [0, 1)
            let nudged = w + Float32(0.001)                 // strictly > 0
            weights.append(nudged)
            total += nudged
        }
        for i in 0..<k {
            weights[i] /= total
        }
        return weights
    }
}
