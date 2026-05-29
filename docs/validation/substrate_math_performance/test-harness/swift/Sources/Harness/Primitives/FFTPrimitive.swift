// FFTPrimitive.swift
//
// FFT (cookbook § 8.10). Mirror of rust/src/primitives/fft.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-FFT.swift
// via the GeniusLocusReference Swift package.
//
// Exercises `magnitudeSpectrum`: a power-of-two length real input
// signal returns a magnitude spectrum (also length n, with bin k
// representing frequency k/n). Both ports use Cooley-Tukey
// radix-2 with bit-reverse permutation; outputs must be f64 bit-
// identical given matching trig library.
//
// Input schema:
//   signal : array of f64 (length must be power of two)
//
// Output schema:
//   spectrum : array of f64 (magnitudes, same length as signal)

import Foundation
import GeniusLocusReference

public enum FFTPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "fft",
        cookbookSection: "§8.10",
        referenceFile: "glref-swift-FFT.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Cycle signal lengths through {4, 8, 16, 32}.
            let n = 1 << ((i % 4) + 2)
            var signal = [Double]()
            for _ in 0..<n {
                let raw = rng.next()
                let v = (Double(raw >> 11) / Double(1 << 53)) * 2.0 - 1.0
                signal.append(v)
            }

            let spectrum = FFT.magnitudeSpectrum(real: signal)

            let signalArr: JSONValue = .array(signal.map { .string(HexCoding.f64($0)) })
            let spectrumArr: JSONValue = .array(spectrum.map { .string(HexCoding.f64($0)) })

            let inputs = JSONDict([
                ("signal", signalArr),
            ])
            let output = JSONDict([
                ("spectrum", spectrumArr),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "n=\(n)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "fft",
            cookbookSection: "§8.10",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-FFT.swift"),
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
        guard case .array(let arr) = c.inputs.get("signal") ?? .null else {
            return fail(c, "missing signal")
        }
        var signal = [Double]()
        for v in arr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                return fail(c, "malformed signal element")
            }
            signal.append(f)
        }

        let actual = FFT.magnitudeSpectrum(real: signal)

        guard case .array(let expArr) = c.expectedOutput.get("spectrum") ?? .null else {
            return fail(c, "missing expected spectrum")
        }
        var expected = [Double]()
        for v in expArr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                return fail(c, "malformed expected spectrum element")
            }
            expected.append(f)
        }

        if actual.count != expected.count {
            return fail(c, "spectrum length mismatch: \(actual.count) vs \(expected.count)")
        }

        for f in actual { encoder.writeF64(f) }

        for k in 0..<actual.count {
            if actual[k].bitPattern != expected[k].bitPattern {
                return ValidationResult.CaseResult(
                    id: c.id, passed: false,
                    diagnostic: "spectrum[\(k)] mismatch: expected \(HexCoding.f64(expected[k])), got \(HexCoding.f64(actual[k]))")
            }
        }

        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .array(let arr) = output.get("spectrum") ?? .null else {
            fatalError("expected_output missing spectrum")
        }
        for v in arr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                fatalError("malformed spectrum element")
            }
            encoder.writeF64(f)
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }
}
