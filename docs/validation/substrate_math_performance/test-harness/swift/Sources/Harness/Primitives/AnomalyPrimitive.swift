// AnomalyPrimitive.swift
//
// Anomaly detection (cookbook § 8.13) — rolling z-score. Mirror
// of rust/src/primitives/anomaly.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-AnomalyDetection.swift
// via the GeniusLocusReference Swift package.
//
// Vector regeneration note: the Path 1 stub was Double-based and
// computed the rolling z-score formula inline; the real reference
// is Float32. This is a legitimate vector regeneration event
// documented in test-vector-format.md.
//
// Input schema:
//   current : f32  (8-hex-digit IEEE-754 bit pattern)
//   window  : array of f32
//
// Output schema:
//   z_score : f32

import Foundation
import GeniusLocusReference

public enum AnomalyPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "anomaly",
        cookbookSection: "§8.13",
        referenceFile: "glref-swift-AnomalyDetection.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Window size cycles 4, 8, 16, 32.
            let windowSize = 1 << ((i % 4) + 2)
            var window = [Float32]()
            for _ in 0..<windowSize {
                window.append(f32FromUInt64Signed(rng.next(), scale: 100.0))
            }
            let current = f32FromUInt64Signed(rng.next(), scale: 100.0)

            let z = AnomalyDetection.rollingZScore(window: window, current: current)

            let windowArr: JSONValue = .array(window.map { .string(HexCoding.f32($0)) })
            let inputs = JSONDict([
                ("current", .string(HexCoding.f32(current))),
                ("window",  windowArr),
            ])
            let output = JSONDict([
                ("z_score", .string(HexCoding.f32(z))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: String(format: "window size %d, current %.4f",
                                     windowSize, Double(current)),
                inputs: inputs,
                expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "anomaly",
            cookbookSection: "§8.13",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-AnomalyDetection.swift"),
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
        guard case .array(let wArr) = c.inputs.get("window") ?? .null else {
            return fail(c, "missing window")
        }
        var window = [Float32]()
        for v in wArr {
            guard case .string(let s) = v,
                  let f = parseF32Hex(s) else {
                return fail(c, "malformed window element")
            }
            window.append(f)
        }
        guard case .string(let cs) = c.inputs.get("current") ?? .null,
              let current = parseF32Hex(cs) else {
            return fail(c, "missing or malformed current")
        }

        let actual = AnomalyDetection.rollingZScore(window: window, current: current)

        guard case .string(let es) = c.expectedOutput.get("z_score") ?? .null,
              let expected = parseF32Hex(es) else {
            return fail(c, "missing or malformed expected z_score")
        }

        encoder.writeF32(actual)

        if actual.bitPattern == expected.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "z_score mismatch: expected \(HexCoding.f32(expected)), got \(HexCoding.f32(actual))"
            )
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("z_score") ?? .null,
              let f = parseF32Hex(s) else {
            fatalError("expected_output missing or malformed z_score")
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
        for (i, b) in bytes.enumerated() {
            bits |= UInt32(b) << (i * 8)
        }
        return Float32(bitPattern: bits)
    }

    /// Map a u64 to a signed Float32 in [-scale, +scale]. Matches
    /// the Rust mirror so the same RNG seed produces the same
    /// Float32 values in both languages.
    private static func f32FromUInt64Signed(_ raw: UInt64, scale: Float32) -> Float32 {
        let normalized = (Float32(raw >> 40) / Float32(1 << 24)) * 2.0 - 1.0
        return normalized * scale
    }
}
