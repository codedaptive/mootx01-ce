// MatrixDecayPrimitive.swift
//
// Exponential matrix decay (cookbook §6.8 / §8.13) — promotes the
// `matrix_decay` reference into the conformance harness per the
// "Pending future work" entry in primitive-catalog.md.
//
// Wired to the real reference at
// GeniusLocusReference/glref-swift-MatrixDecay.swift via the
// GeniusLocusReference Swift package.
//
// Mirror: rust/src/primitives/matrix_decay.rs
//
// Input schema:
//   rows                      : u32  (decimal integer)
//   cols                      : u32  (decimal integer)
//   half_life_seconds         : f64  (16-hex IEEE-754 bit pattern, LE)
//   last_decay_time_seconds   : i64  (decimal integer)
//   now_seconds               : i64  (decimal integer)
//   initial_values            : array of f64 (each 16-hex IEEE-754 LE)
//
// Output schema:
//   final_last_decay_time_seconds : i64
//   final_values                  : array of f64
//
// Binary canonical encoding (alphabetical key order per spec):
//   final_last_decay_time_seconds  (8 bytes i64 LE)
//   final_values                   (u32 LE length + N × 8 bytes f64 LE)
//
// Cross-language bit-identity assumption: on Apple Silicon, Swift's
// Foundation `exp()` and Rust's `f64::exp()` resolve to the same
// libm (Darwin's libsystem_m), so transcendental results agree
// bit-for-bit. The test design preferentially uses cases where
// the decay factor is a power of 1/2 (dt = k × half_life, k ∈ ℕ),
// for which the multiplication is exact regardless of libm
// implementation. A minority of cases use arbitrary dt to surface
// any cross-libm divergence as a CRC mismatch.

import Foundation
import GeniusLocusReference

public enum MatrixDecayPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "matrix_decay",
        cookbookSection: "§6.8",
        referenceFile: "glref-swift-MatrixDecay.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let (rows, cols) = matrixShape(forCaseIndex: i)
            let halfLife = halfLifeSeconds(rng: &rng)
            let lastDecayTime = lastDecaySeconds(rng: &rng)
            let nowSeconds = nowSecondsForCase(i, lastDecayTime: lastDecayTime,
                                                halfLife: halfLife, rng: &rng)

            var initialValues = [Double]()
            initialValues.reserveCapacity(rows * cols)
            for _ in 0..<(rows * cols) {
                initialValues.append(f64FromUInt64Signed(rng.next(), scale: 100.0))
            }

            var matrix = DecayingMatrix(
                rows: rows, cols: cols,
                halfLifeSeconds: halfLife,
                lastDecayTimeSeconds: lastDecayTime)
            for r in 0..<rows {
                for c in 0..<cols {
                    matrix[r, c] = initialValues[r * cols + c]
                }
            }

            MatrixDecay.apply(to: &matrix, nowSeconds: nowSeconds)

            let initialJSON: JSONValue = .array(
                initialValues.map { .string(HexCoding.f64($0)) })
            let finalJSON: JSONValue = .array(
                matrix.values.map { .string(HexCoding.f64($0)) })

            let inputs = JSONDict([
                ("rows",                    .integer(Int64(rows))),
                ("cols",                    .integer(Int64(cols))),
                ("half_life_seconds",       .string(HexCoding.f64(halfLife))),
                ("last_decay_time_seconds", .integer(lastDecayTime)),
                ("now_seconds",             .integer(nowSeconds)),
                ("initial_values",          initialJSON),
            ])
            let output = JSONDict([
                ("final_last_decay_time_seconds",
                    .integer(matrix.lastDecayTimeSeconds)),
                ("final_values",            finalJSON),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: caseDescription(
                    index: i, rows: rows, cols: cols,
                    halfLife: halfLife,
                    dt: Double(nowSeconds - lastDecayTime)),
                inputs: inputs,
                expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "matrix_decay",
            cookbookSection: "§6.8",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-MatrixDecay.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases {
            caseResults.append(validateCase(c, encoder: &encoder))
        }
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
        guard case .integer(let rowsI) = c.inputs.get("rows") ?? .null,
              let rows = Int(exactly: rowsI), rows > 0 else {
            return fail(c, "missing or invalid rows")
        }
        guard case .integer(let colsI) = c.inputs.get("cols") ?? .null,
              let cols = Int(exactly: colsI), cols > 0 else {
            return fail(c, "missing or invalid cols")
        }
        guard case .string(let hlHex) = c.inputs.get("half_life_seconds") ?? .null,
              let halfLife = parseF64Hex(hlHex) else {
            return fail(c, "missing or malformed half_life_seconds")
        }
        guard case .integer(let lastDecayTime) = c.inputs.get("last_decay_time_seconds") ?? .null else {
            return fail(c, "missing last_decay_time_seconds")
        }
        guard case .integer(let nowSeconds) = c.inputs.get("now_seconds") ?? .null else {
            return fail(c, "missing now_seconds")
        }
        guard case .array(let initArr) = c.inputs.get("initial_values") ?? .null else {
            return fail(c, "missing initial_values")
        }
        guard initArr.count == rows * cols else {
            return fail(c, "initial_values count mismatch")
        }
        var initialValues = [Double]()
        initialValues.reserveCapacity(rows * cols)
        for v in initArr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                return fail(c, "malformed initial_values element")
            }
            initialValues.append(f)
        }

        var matrix = DecayingMatrix(
            rows: rows, cols: cols,
            halfLifeSeconds: halfLife,
            lastDecayTimeSeconds: lastDecayTime)
        for r in 0..<rows {
            for c2 in 0..<cols {
                matrix[r, c2] = initialValues[r * cols + c2]
            }
        }
        MatrixDecay.apply(to: &matrix, nowSeconds: nowSeconds)

        guard case .integer(let expectedLastDecay) = c.expectedOutput.get("final_last_decay_time_seconds") ?? .null else {
            return fail(c, "missing expected final_last_decay_time_seconds")
        }
        guard case .array(let finalArr) = c.expectedOutput.get("final_values") ?? .null else {
            return fail(c, "missing expected final_values")
        }
        guard finalArr.count == rows * cols else {
            return fail(c, "expected final_values count mismatch")
        }
        var expectedFinal = [Double]()
        expectedFinal.reserveCapacity(rows * cols)
        for v in finalArr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                return fail(c, "malformed expected final_values element")
            }
            expectedFinal.append(f)
        }

        encoder.writeI64(matrix.lastDecayTimeSeconds)
        encoder.writeU32(UInt32(matrix.values.count))
        for v in matrix.values { encoder.writeF64(v) }

        if matrix.lastDecayTimeSeconds != expectedLastDecay {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "final_last_decay_time_seconds mismatch: expected \(expectedLastDecay), got \(matrix.lastDecayTimeSeconds)")
        }
        for (idx, (actual, expected)) in zip(matrix.values, expectedFinal).enumerated() {
            if actual.bitPattern != expected.bitPattern {
                return ValidationResult.CaseResult(
                    id: c.id, passed: false,
                    diagnostic: "final_values[\(idx)] mismatch: expected \(HexCoding.f64(expected)), got \(HexCoding.f64(actual))")
            }
        }
        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .integer(let lastDecay) = output.get("final_last_decay_time_seconds") ?? .null else {
            fatalError("expected_output missing final_last_decay_time_seconds")
        }
        guard case .array(let arr) = output.get("final_values") ?? .null else {
            fatalError("expected_output missing final_values")
        }
        encoder.writeI64(lastDecay)
        encoder.writeU32(UInt32(arr.count))
        for v in arr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                fatalError("malformed final_values hex")
            }
            encoder.writeF64(f)
        }
    }

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt64(b) << (i * 8)
        }
        return Double(bitPattern: bits)
    }

    private static func f64FromUInt64Signed(_ raw: UInt64, scale: Double) -> Double {
        let normalized = (Double(raw >> 11) / Double(1 << 53)) * 2.0 - 1.0
        return normalized * scale
    }

    private static func matrixShape(forCaseIndex i: Int) -> (rows: Int, cols: Int) {
        let shapes: [(Int, Int)] = [
            (1, 1), (1, 1), (1, 1), (1, 1),
            (2, 3), (3, 2), (2, 3), (3, 2),
            (4, 4), (4, 4), (4, 4), (4, 4),
            (1, 8), (8, 1), (5, 5), (3, 4),
            (1, 1), (2, 2), (3, 3), (4, 4),
            (2, 3), (3, 2), (4, 4), (5, 5),
            (1, 1), (1, 1), (1, 1), (1, 1),
            (3, 3), (4, 4), (2, 5), (5, 2),
        ]
        return shapes[i]
    }

    private static func halfLifeSeconds(rng: inout SplitMix64) -> Double {
        let r = rng.next()
        let normalized = Double(r >> 11) / Double(1 << 53)
        let minSec = 60.0 * 86400.0
        let maxSec = 730.0 * 86400.0
        return minSec + normalized * (maxSec - minSec)
    }

    private static func lastDecaySeconds(rng: inout SplitMix64) -> Int64 {
        let r = rng.next()
        return Int64(r % UInt64(10 * 365 * 86400))
    }

    private static func nowSecondsForCase(_ i: Int,
                                           lastDecayTime: Int64,
                                           halfLife: Double,
                                           rng: inout SplitMix64) -> Int64 {
        switch i {
        case 24:
            return lastDecayTime
        case 25:
            return lastDecayTime - 1000
        case 26:
            return lastDecayTime + Int64(halfLife)
        case 27:
            return lastDecayTime + Int64(halfLife * 2.0)
        default:
            let r = rng.next()
            let normalized = Double(r >> 11) / Double(1 << 53)
            let dt = 1.0 + normalized * 3.0 * halfLife
            return lastDecayTime + Int64(dt)
        }
    }

    private static func caseDescription(index: Int, rows: Int, cols: Int,
                                          halfLife: Double, dt: Double) -> String {
        let halfLifeDays = halfLife / 86400.0
        let halfLivesElapsed = dt / halfLife
        return String(format: "case %d: %dx%d, half_life %.2f days, %.4f half-lives elapsed",
                       index, rows, cols, halfLifeDays, halfLivesElapsed)
    }
}
