// FieldPresenceMatrixFPrimitive.swift
//
// Field-presence matrix F (cookbook §6.1) — promotes the
// `field_presence_matrix_f` reference into the conformance
// harness per the "Pending future work" entry in
// primitive-catalog.md.
//
// Wired to the real reference at
// GeniusLocusReference/glref-swift-MatrixF.swift via the
// GeniusLocusReference Swift package.
//
// Mirror: rust/src/primitives/field_presence_matrix_f.rs
//
// MatrixF is a population statistic: 36 fields × 6 bits-per-field
// = 216 i64 cells, indexed cells[field * 6 + bit]. The
// `apply_row(delta, bit_presence)` operation walks the 216 (field,
// bit) positions and adds `delta` to each cell where
// bit_presence(field, bit) is true. Inverse operations cancel
// (linearity). MatrixF does NOT decay (cookbook §6.8 has F's
// half_life = None).
//
// The harness tests the full update path:
//   1. Start from an arbitrary initial MatrixF state (cells).
//   2. Apply a sequence of (delta, bit_presence_pattern) ops.
//   3. Compare the final MatrixF wire bytes.
//
// "bit_presence_pattern" is encoded as 216 bits packed LSB-first
// into 27 bytes (hex-string of 54 chars). Bit at position
// `field * 6 + bit` is the bit_presence value for that cell.
//
// Input schema:
//   initial_cells : array of i64 (length 216) — initial F state
//   operations    : array of {bit_presence: 54-hex (27 bytes), delta: i64}
//
// Output schema:
//   final_cells : array of i64 (length 216) — F after all ops
//
// Binary canonical encoding (alphabetical key order, single field):
//   final_cells : u32 LE length (216) + 216 × 8 bytes i64 LE
//
// Cross-language bit-identity: integer-only (i64 wrapping addition,
// boolean bit-presence lookup, fixed 216-iteration loop). No
// transcendentals. Apple and non-Apple platforms behave identically
// per IEEE-754 integer wrap semantics.

import Foundation
import GeniusLocusReference

public enum FieldPresenceMatrixFPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "field_presence_matrix_f",
        cookbookSection: "§6.1",
        referenceFile: "glref-swift-MatrixF.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let spec = generateCaseSpec(i, rng: &rng)
            let finalCells = applyOps(initial: spec.initialCells, ops: spec.operations)

            let initialJSON: JSONValue = .array(spec.initialCells.map { .integer($0) })
            let opsJSON: JSONValue = .array(spec.operations.map { op in
                .dict(JSONDict([
                    ("bit_presence", .string(HexCoding.encode(op.bitPresence))),
                    ("delta",        .integer(op.delta)),
                ]))
            })
            let finalJSON: JSONValue = .array(finalCells.map { .integer($0) })

            let inputs = JSONDict([
                ("initial_cells", initialJSON),
                ("operations",    opsJSON),
            ])
            let output = JSONDict([
                ("final_cells", finalJSON),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: spec.description,
                inputs: inputs,
                expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "field_presence_matrix_f",
            cookbookSection: "§6.1",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-MatrixF.swift"),
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
        guard case .array(let initArr) = c.inputs.get("initial_cells") ?? .null else {
            return fail(c, "missing initial_cells")
        }
        if initArr.count != MatrixF.cellCount {
            return fail(c, "initial_cells length \(initArr.count) != \(MatrixF.cellCount)")
        }
        var initialCells = [Int64](repeating: 0, count: MatrixF.cellCount)
        for (idx, v) in initArr.enumerated() {
            guard case .integer(let n) = v else {
                return fail(c, "initial_cells[\(idx)] not an integer")
            }
            initialCells[idx] = n
        }

        guard case .array(let opsArr) = c.inputs.get("operations") ?? .null else {
            return fail(c, "missing operations")
        }
        var ops = [Operation]()
        ops.reserveCapacity(opsArr.count)
        for (idx, ov) in opsArr.enumerated() {
            guard case .dict(let od) = ov else {
                return fail(c, "operations[\(idx)] not a dict")
            }
            guard case .integer(let delta) = od.get("delta") ?? .null else {
                return fail(c, "operations[\(idx)] missing delta")
            }
            guard case .string(let bpHex) = od.get("bit_presence") ?? .null,
                  let bp = try? HexCoding.decode(bpHex), bp.count == bitPresenceBytes else {
                return fail(c, "operations[\(idx)] missing or malformed bit_presence")
            }
            ops.append(Operation(delta: delta, bitPresence: bp))
        }

        let actual = applyOps(initial: initialCells, ops: ops)

        guard case .array(let expectedArr) = c.expectedOutput.get("final_cells") ?? .null else {
            return fail(c, "missing expected final_cells")
        }
        if expectedArr.count != MatrixF.cellCount {
            return fail(c, "expected final_cells length mismatch")
        }

        encoder.writeU32(UInt32(actual.count))
        for v in actual { encoder.writeI64(v) }

        for (idx, ev) in expectedArr.enumerated() {
            guard case .integer(let expected) = ev else {
                return fail(c, "expected final_cells[\(idx)] not an integer")
            }
            if actual[idx] != expected {
                return ValidationResult.CaseResult(
                    id: c.id, passed: false,
                    diagnostic: "final_cells[\(idx)] mismatch: expected \(expected), got \(actual[idx])")
            }
        }
        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .array(let arr) = output.get("final_cells") ?? .null else {
            fatalError("expected_output missing final_cells")
        }
        encoder.writeU32(UInt32(arr.count))
        for v in arr {
            guard case .integer(let n) = v else {
                fatalError("non-integer final_cells element")
            }
            encoder.writeI64(n)
        }
    }

    // MARK: - Algorithm

    private struct Operation {
        let delta: Int64
        /// 216 bits packed LSB-first into 27 bytes.
        let bitPresence: [UInt8]
    }

    private static let bitPresenceBytes = 27  // 216 bits / 8 = 27

    private static func applyOps(initial: [Int64], ops: [Operation]) -> [Int64] {
        var matrix = MatrixF(cells: initial)
        for op in ops {
            let bp = op.bitPresence
            matrix.applyRow(delta: op.delta) { field, bit in
                let pos = field * MatrixF.bitsPerField + bit
                let byteIdx = pos / 8
                let bitIdx = pos % 8
                return (bp[byteIdx] >> bitIdx) & 1 == 1
            }
        }
        return matrix.cells
    }

    // MARK: - Case generation

    private struct CaseSpec {
        let initialCells: [Int64]
        let operations: [Operation]
        let description: String
    }

    private static func generateCaseSpec(_ i: Int, rng: inout SplitMix64) -> CaseSpec {
        switch i {
        case 0:
            return CaseSpec(
                initialCells: [Int64](repeating: 0, count: MatrixF.cellCount),
                operations: [],
                description: "empty (no ops on zero matrix)")
        case 1:
            // Single +1 op with all bits set.
            return CaseSpec(
                initialCells: [Int64](repeating: 0, count: MatrixF.cellCount),
                operations: [Operation(delta: 1,
                                        bitPresence: allBitsSet())],
                description: "+1 with all 216 bits set")
        case 2:
            // Single +1 op with no bits set (no-op).
            return CaseSpec(
                initialCells: [Int64](repeating: 0, count: MatrixF.cellCount),
                operations: [Operation(delta: 1,
                                        bitPresence: allBitsClear())],
                description: "+1 with no bits set (no-op)")
        case 3:
            // Inverse pair: +1 then -1 should be no-op.
            let pattern = randomBitPattern(&rng)
            return CaseSpec(
                initialCells: [Int64](repeating: 0, count: MatrixF.cellCount),
                operations: [
                    Operation(delta: 1, bitPresence: pattern),
                    Operation(delta: -1, bitPresence: pattern),
                ],
                description: "+1 then -1 inverse pair")
        case 4...7:
            // Seeded initial state + single op.
            var initial = [Int64](repeating: 0, count: MatrixF.cellCount)
            for k in 0..<MatrixF.cellCount {
                initial[k] = Int64(bitPattern: rng.next())
            }
            let pattern = randomBitPattern(&rng)
            let delta = Int64([1, -1, 100, -100][i - 4])
            return CaseSpec(
                initialCells: initial,
                operations: [Operation(delta: delta, bitPresence: pattern)],
                description: "seeded initial, single op delta=\(delta)")
        case 8...15:
            // Inverse-pair restoration with non-zero initial.
            var initial = [Int64](repeating: 0, count: MatrixF.cellCount)
            for k in 0..<MatrixF.cellCount {
                initial[k] = Int64(bitPattern: rng.next()) & 0xFFFF_FFFF  // bounded
            }
            let pattern1 = randomBitPattern(&rng)
            let pattern2 = randomBitPattern(&rng)
            return CaseSpec(
                initialCells: initial,
                operations: [
                    Operation(delta: 5,  bitPresence: pattern1),
                    Operation(delta: -3, bitPresence: pattern2),
                    Operation(delta: 1,  bitPresence: pattern1),
                ],
                description: "seeded initial, three mixed ops (case \(i))")
        default:
            // Random sequences.
            var initial = [Int64](repeating: 0, count: MatrixF.cellCount)
            for k in 0..<MatrixF.cellCount {
                initial[k] = Int64(bitPattern: rng.next()) & 0xFFFF
            }
            let opCount = 1 + Int(rng.next() % 12)
            var ops = [Operation]()
            ops.reserveCapacity(opCount)
            for _ in 0..<opCount {
                let dRaw = Int32(bitPattern: UInt32(rng.next() & 0xFFFF_FFFF))
                let delta = Int64(dRaw % 200)
                let pattern = randomBitPattern(&rng)
                ops.append(Operation(delta: delta, bitPresence: pattern))
            }
            return CaseSpec(
                initialCells: initial,
                operations: ops,
                description: "random sequence of \(opCount) ops")
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func allBitsSet() -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: bitPresenceBytes)
        // 216 bits exactly; last byte has 8 bits, all 216 fit.
        // 27 bytes × 8 = 216. Perfect alignment, no spare bits.
        // (If the count were different, mask the spare bits to 0.)
        _ = out
        return out
    }

    private static func allBitsClear() -> [UInt8] {
        return [UInt8](repeating: 0, count: bitPresenceBytes)
    }

    private static func randomBitPattern(_ rng: inout SplitMix64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bitPresenceBytes)
        var i = 0
        while i < bitPresenceBytes {
            let word = rng.next()
            for k in 0..<8 {
                if i + k >= bitPresenceBytes { break }
                out[i + k] = UInt8((word >> (k * 8)) & 0xFF)
            }
            i += 8
        }
        return out
    }
}
