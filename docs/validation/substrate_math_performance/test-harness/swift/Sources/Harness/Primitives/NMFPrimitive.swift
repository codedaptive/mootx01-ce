// NMFPrimitive.swift
//
// Non-negative matrix factorization via multiplicative-update
// alternating least squares (cookbook § 6.9). Mirror of
// rust/src/primitives/nmf.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-NMFAlternatingLeastSquares.swift
// via the GeniusLocusReference Swift package.
//
// Determinism: NMF here is f32, iterative, and ordering-sensitive.
// Bit-identical W and H across Swift and Rust requires:
//   1. Same SplitMix64 seed and same number of draws to init W, H.
//   2. Same loop order for the multiplicative updates.
//   3. Same operand order in every f32 multiply and add.
// Both ports verified compliant by reading the factorize bodies
// side by side; the cross-language conformance test confirms.
//
// Cases use small matrices (4-8 rows, 3-6 cols, rank 2 or 3) so
// the test runs quickly and accumulation order is controlled.
//
// Input schema:
//   m              : u32 hex (matrix rows)
//   n              : u32 hex (matrix cols)
//   rank           : u32 hex
//   max_iterations : u32 hex
//   tolerance      : f32 hex
//   inner_seed     : u64 hex (seed passed to factorize, NOT the
//                             vector-gen seed)
//   v              : array of arrays of f32 (m × n matrix)
//
// Output schema:
//   iterations  : u32 hex
//   final_error : f32 hex
//   w           : array of arrays of f32 (m × rank)
//   h           : array of arrays of f32 (rank × n)

import Foundation
import GeniusLocusReference

public enum NMFPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "nmf",
        cookbookSection: "§6.9",
        referenceFile: "glref-swift-NMFAlternatingLeastSquares.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Cycle matrix shapes through (m, n, rank).
            let shapes: [(Int, Int, Int)] = [
                (4, 3, 2), (5, 4, 2), (6, 5, 3), (8, 6, 3),
            ]
            let (m, n, rank) = shapes[i % shapes.count]
            let maxIterations = 20 + (i % 4) * 5
            let tolerance: Float32 = 1e-4
            let innerSeed = rng.next()

            // Build V from non-negative f32 values.
            var V = [[Float32]]()
            for _ in 0..<m {
                var row = [Float32]()
                for _ in 0..<n {
                    let raw = rng.next()
                    let v = Float32(raw >> 40) / Float32(1 << 24)  // [0, 1)
                    row.append(v)
                }
                V.append(row)
            }

            let result = NMFAlternatingLeastSquares.factorize(
                V: V, rank: rank,
                maxIterations: maxIterations,
                tolerance: tolerance,
                seed: innerSeed)

            let vArr: JSONValue = .array(V.map { row -> JSONValue in
                .array(row.map { .string(HexCoding.f32($0)) })
            })
            let wArr: JSONValue = .array(result.W.map { row -> JSONValue in
                .array(row.map { .string(HexCoding.f32($0)) })
            })
            let hArr: JSONValue = .array(result.H.map { row -> JSONValue in
                .array(row.map { .string(HexCoding.f32($0)) })
            })

            let inputs = JSONDict([
                ("m",              .string(HexCoding.u32(UInt32(m)))),
                ("n",              .string(HexCoding.u32(UInt32(n)))),
                ("rank",           .string(HexCoding.u32(UInt32(rank)))),
                ("max_iterations", .string(HexCoding.u32(UInt32(maxIterations)))),
                ("tolerance",      .string(HexCoding.f32(tolerance))),
                ("inner_seed",     .string(HexCoding.u64(innerSeed))),
                ("v",              vArr),
            ])
            let output = JSONDict([
                ("iterations",  .string(HexCoding.u32(UInt32(result.iterations)))),
                ("final_error", .string(HexCoding.f32(result.finalError))),
                ("w",           wArr),
                ("h",           hArr),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "m=\(m), n=\(n), rank=\(rank), maxIter=\(maxIterations)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "nmf",
            cookbookSection: "§6.9",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-NMFAlternatingLeastSquares.swift"),
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
        guard let rank = parseU32(c.inputs.get("rank")) else { return fail(c, "missing rank") }
        guard let maxIterations = parseU32(c.inputs.get("max_iterations")) else { return fail(c, "missing max_iterations") }
        guard let tolerance = parseF32(c.inputs.get("tolerance")) else { return fail(c, "missing tolerance") }
        guard let innerSeed = parseU64(c.inputs.get("inner_seed")) else { return fail(c, "missing inner_seed") }

        guard case .array(let vRows) = c.inputs.get("v") ?? .null else {
            return fail(c, "missing V")
        }
        var V = [[Float32]]()
        for row in vRows {
            guard case .array(let cells) = row else { return fail(c, "V row not array") }
            var r = [Float32]()
            for cell in cells {
                guard case .string(let s) = cell, let f = parseF32Hex(s) else {
                    return fail(c, "V cell malformed")
                }
                r.append(f)
            }
            V.append(r)
        }

        let result = NMFAlternatingLeastSquares.factorize(
            V: V, rank: Int(rank),
            maxIterations: Int(maxIterations),
            tolerance: tolerance,
            seed: innerSeed)

        guard let expectedIterations = parseU32(c.expectedOutput.get("iterations")) else {
            return fail(c, "missing expected iterations")
        }
        guard let expectedFinalError = parseF32(c.expectedOutput.get("final_error")) else {
            return fail(c, "missing expected final_error")
        }
        guard case .array(let expWRows) = c.expectedOutput.get("w") ?? .null else {
            return fail(c, "missing expected W")
        }
        guard case .array(let expHRows) = c.expectedOutput.get("h") ?? .null else {
            return fail(c, "missing expected H")
        }

        // Encode actual to canonical binary.
        encoder.writeU32(UInt32(result.iterations))
        encoder.writeF32(result.finalError)
        for row in result.W { for v in row { encoder.writeF32(v) } }
        for row in result.H { for v in row { encoder.writeF32(v) } }

        if UInt32(result.iterations) != expectedIterations {
            return fail(c, "iterations mismatch: expected \(expectedIterations), got \(result.iterations)")
        }
        if result.finalError.bitPattern != expectedFinalError.bitPattern {
            return fail(c, "final_error mismatch: expected \(HexCoding.f32(expectedFinalError)), got \(HexCoding.f32(result.finalError))")
        }
        if let err = compareMatrix(result.W, expRows: expWRows, name: "W") {
            return fail(c, err)
        }
        if let err = compareMatrix(result.H, expRows: expHRows, name: "H") {
            return fail(c, err)
        }

        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard let iterations = parseU32(output.get("iterations")) else {
            fatalError("expected_output missing iterations")
        }
        guard let finalError = parseF32(output.get("final_error")) else {
            fatalError("expected_output missing final_error")
        }
        encoder.writeU32(iterations)
        encoder.writeF32(finalError)

        for matKey in ["w", "h"] {
            guard case .array(let rows) = output.get(matKey) ?? .null else {
                fatalError("expected_output missing \(matKey)")
            }
            for row in rows {
                guard case .array(let cells) = row else { fatalError("\(matKey) row not array") }
                for cell in cells {
                    guard case .string(let s) = cell, let f = parseF32Hex(s) else {
                        fatalError("\(matKey) cell malformed")
                    }
                    encoder.writeF32(f)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func compareMatrix(_ actual: [[Float32]],
                                       expRows: [JSONValue],
                                       name: String) -> String? {
        if actual.count != expRows.count {
            return "\(name) row count mismatch: \(actual.count) vs \(expRows.count)"
        }
        for i in 0..<actual.count {
            guard case .array(let cells) = expRows[i] else {
                return "\(name)[\(i)] not array"
            }
            if actual[i].count != cells.count {
                return "\(name)[\(i)] col count mismatch"
            }
            for j in 0..<actual[i].count {
                guard case .string(let s) = cells[j], let f = parseF32Hex(s) else {
                    return "\(name)[\(i)][\(j)] not hex string"
                }
                if actual[i][j].bitPattern != f.bitPattern {
                    return "\(name)[\(i)][\(j)] mismatch: expected \(HexCoding.f32(f)), got \(HexCoding.f32(actual[i][j]))"
                }
            }
        }
        return nil
    }

    private static func parseU32(_ v: JSONValue?) -> UInt32? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var v: UInt32 = 0
        for (i, b) in bytes.enumerated() { v |= UInt32(b) << (i * 8) }
        return v
    }

    private static func parseU64(_ v: JSONValue?) -> UInt64? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (i * 8) }
        return v
    }

    private static func parseF32(_ v: JSONValue?) -> Float32? {
        guard case .string(let s)? = v else { return nil }
        return parseF32Hex(s)
    }

    private static func parseF32Hex(_ s: String) -> Float32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt32(b) << (i * 8) }
        return Float32(bitPattern: bits)
    }
}
