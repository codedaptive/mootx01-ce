// ORReducePrimitive.swift
//
// OR-reduction across scopes (cookbook § 8.5). Mirror of
// rust/src/primitives/or_reduce.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-ORReduce.swift
// via the GeniusLocusReference Swift package.
//
// Input schema (pair-at-a-time cases, 32 of them):
//   count        : u32  (number of fingerprints to reduce)
//   fingerprints : array of Fingerprint256
//
// Output schema (pair):
//   reduced : Fingerprint256
//
// Input schema (batched cases, 8 of them, one per batch_size in
//   {0, 1, 2, 4, 8, 16, 32, 64}). Batched cases test the
//   `orReduceBatch` protocol method: M independent reductions in
//   one call. Each inner batch is a cohort of fingerprints; the
//   inner cohort size cycles through {1, 2, 4, 8}. The outer
//   length is `batch_size`.
//
//   inner_count : u32       (uniform across this case's batches)
//   batches     : [[Fingerprint256]]   (length = batch_size, each
//                                       inner length = inner_count)
//
// Output schema (batched):
//   reduced_batch : [Fingerprint256]   (length = batch_size)
//
// Per the kernel-learned-dispatch decision
//, batched output
// MUST equal sequential output byte-for-byte in at-rest
// little-endian canonical form. The conformance gate enforces
// this.

import Foundation
import GeniusLocusReference

public enum ORReducePrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "or_reduce",
        cookbookSection: "§8.5",
        referenceFile: "glref-swift-ORReduce.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let pairCount = 32

        // ----- Pair-at-a-time cases (unchanged from prior versions).
        for i in 0..<pairCount {
            // Cycle through cohort sizes 1, 2, 4, 8.
            let count: Int = [1, 2, 4, 8][i % 4]
            var cohort = [Fingerprint256]()
            cohort.reserveCapacity(count)
            for _ in 0..<count {
                cohort.append(Fingerprint256(
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next()))
            }

            let reduced = ORReduce.reduce(cohort)

            let fpArr: JSONValue = .array(cohort.map { .string(Self.encodeFingerprint($0)) })
            let inputs = JSONDict([
                ("count",        .string(HexCoding.u32(UInt32(count)))),
                ("fingerprints", fpArr),
            ])
            let output = JSONDict([
                ("reduced", .string(Self.encodeFingerprint(reduced))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: String(format: "cohort size %d", count),
                inputs: inputs, expectedOutput: output))
        }

        // ----- Batched cases (one per batch_size in batchedSizes).
        //
        // Each case picks an inner_count from {1, 2, 4, 8} and
        // builds `batch_size` independent cohorts of that size.
        // The kernel's `orReduceBatch` produces `batch_size`
        // reduced fingerprints in one call.
        let kernel = KernelSelector.current()
        let batchedSizes = [0, 1, 2, 4, 8, 16, 32, 64]
        for (k, batchSize) in batchedSizes.enumerated() {
            let innerCount: Int = [1, 2, 4, 8][k % 4]
            var batches = [[Fingerprint256]]()
            batches.reserveCapacity(batchSize)
            for _ in 0..<batchSize {
                var cohort = [Fingerprint256]()
                cohort.reserveCapacity(innerCount)
                for _ in 0..<innerCount {
                    cohort.append(Fingerprint256(
                        block0: rng.next(), block1: rng.next(),
                        block2: rng.next(), block3: rng.next()))
                }
                batches.append(cohort)
            }

            let reducedBatch = kernel.orReduceBatch(batches: batches)

            let outerArr: JSONValue = .array(
                batches.map { cohort in
                    .array(cohort.map { .string(Self.encodeFingerprint($0)) })
                })
            let inputs = JSONDict([
                ("inner_count", .string(HexCoding.u32(UInt32(innerCount)))),
                ("batches", outerArr),
            ])
            let output = JSONDict([
                ("reduced_batch", .array(
                    reducedBatch.map { .string(Self.encodeFingerprint($0)) })),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", pairCount + k),
                description: "batched, batch_size \(batchSize), inner_count \(innerCount)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "or_reduce",
            cookbookSection: "§8.5",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-ORReduce.swift"),
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
        // Batched cases have a `reduced_batch` array in expected_output.
        // Pair-at-a-time cases have a single `reduced` scalar.
        if case .array = c.expectedOutput.get("reduced_batch") ?? .null {
            return validateBatchedCase(c, encoder: &encoder)
        }
        return validatePairCase(c, encoder: &encoder)
    }

    private static func validatePairCase(_ c: VectorFile.Case,
                                          encoder: inout CanonicalBinaryEncoder)
                                         -> ValidationResult.CaseResult {
        guard case .array(let fpArr) = c.inputs.get("fingerprints") ?? .null else {
            return fail(c, "missing fingerprints")
        }
        var cohort = [Fingerprint256]()
        for v in fpArr {
            guard case .string(let hex) = v,
                  let fp = parseFingerprint(hex) else {
                return fail(c, "malformed fingerprint")
            }
            cohort.append(fp)
        }

        let actual = ORReduce.reduce(cohort)

        guard case .string(let expHex) = c.expectedOutput.get("reduced") ?? .null,
              let expected = parseFingerprint(expHex) else {
            return fail(c, "missing or malformed expected reduced")
        }

        writeFingerprint(actual, encoder: &encoder)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "reduced mismatch: expected \(encodeFingerprint(expected)), got \(encodeFingerprint(actual))")
        }
    }

    private static func validateBatchedCase(_ c: VectorFile.Case,
                                             encoder: inout CanonicalBinaryEncoder)
                                            -> ValidationResult.CaseResult {
        guard case .array(let outerArr) = c.inputs.get("batches") ?? .null else {
            return fail(c, "missing batches")
        }
        var batches = [[Fingerprint256]]()
        batches.reserveCapacity(outerArr.count)
        for cohortVal in outerArr {
            guard case .array(let cohortArr) = cohortVal else {
                return fail(c, "batches element not an array")
            }
            var cohort = [Fingerprint256]()
            cohort.reserveCapacity(cohortArr.count)
            for v in cohortArr {
                guard case .string(let hex) = v,
                      let fp = parseFingerprint(hex) else {
                    return fail(c, "malformed fingerprint in batch")
                }
                cohort.append(fp)
            }
            batches.append(cohort)
        }

        guard case .array(let expArr) = c.expectedOutput.get("reduced_batch") ?? .null else {
            return fail(c, "missing expected reduced_batch")
        }
        var expected = [Fingerprint256]()
        expected.reserveCapacity(expArr.count)
        for v in expArr {
            guard case .string(let hex) = v,
                  let fp = parseFingerprint(hex) else {
                return fail(c, "malformed expected reduced")
            }
            expected.append(fp)
        }

        guard batches.count == expected.count else {
            return fail(c, "length mismatch: \(batches.count) batches vs \(expected.count) expected")
        }

        let kernel = KernelSelector.current()
        let actual = kernel.orReduceBatch(batches: batches)

        // Canonical binary encoding: u32 LE length prefix + N Fingerprint256
        // (each as 4 u64 LE = 32 bytes).
        encoder.writeU32(UInt32(actual.count))
        for fp in actual { writeFingerprint(fp, encoder: &encoder) }

        let firstDiff = (0..<actual.count).first(where: { actual[$0] != expected[$0] })
        if firstDiff == nil {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            let i = firstDiff!
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "batched reduced mismatch at index \(i): expected \(encodeFingerprint(expected[i])), got \(encodeFingerprint(actual[i]))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        // Dispatch on schema. Order MUST match validateCase so generator
        // and validator produce identical canonical byte streams.
        if case .array(let arr) = output.get("reduced_batch") ?? .null {
            encoder.writeU32(UInt32(arr.count))
            for item in arr {
                guard case .string(let s) = item,
                      let fp = parseFingerprint(s) else {
                    fatalError("malformed batched reduced hex")
                }
                writeFingerprint(fp, encoder: &encoder)
            }
            return
        }

        guard case .string(let s) = output.get("reduced") ?? .null,
              let fp = parseFingerprint(s) else {
            fatalError("expected_output missing or malformed reduced")
        }
        writeFingerprint(fp, encoder: &encoder)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func writeFingerprint(_ fp: Fingerprint256, encoder: inout CanonicalBinaryEncoder) {
        encoder.writeU64(fp.block0)
        encoder.writeU64(fp.block1)
        encoder.writeU64(fp.block2)
        encoder.writeU64(fp.block3)
    }

    private static func encodeFingerprint(_ fp: Fingerprint256) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let blocks = [fp.block0, fp.block1, fp.block2, fp.block3]
        for (i, w) in blocks.enumerated() {
            for j in 0..<8 { bytes[i * 8 + j] = UInt8((w >> (j * 8)) & 0xFF) }
        }
        return HexCoding.encode(bytes)
    }

    private static func parseFingerprint(_ s: String) -> Fingerprint256? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 32 else { return nil }
        var blocks = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blocks[i] = w
        }
        return Fingerprint256(block0: blocks[0], block1: blocks[1],
                              block2: blocks[2], block3: blocks[3])
    }
}
