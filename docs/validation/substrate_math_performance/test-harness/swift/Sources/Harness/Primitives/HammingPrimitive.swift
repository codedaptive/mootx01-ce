// HammingPrimitive.swift
//
// Hamming distance over Fingerprint256 (cookbook § 8.2). Mirror
// of rust/src/primitives/hamming.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-Hamming.swift
// via the GeniusLocusReference Swift package. Cross-language
// conformance with the Rust mirror is gated on the CRC32 of the
// canonical-binary serialization of all case outputs.
//
// Input schema (pair-at-a-time cases, 32 of them):
//   a              : Fingerprint256 (32-byte hex, LE)
//   b              : Fingerprint256
//   blocks_bitmask : u8 in 0..16 (bit 0=block0, bit 1=block1, ...)
//
// Output schema (pair):
//   distance : u32 (popcount of (a XOR b) restricted to the requested blocks)
//
// Input schema (batched cases, 8 of them, one per batch_size in
//   {0, 1, 2, 4, 8, 16, 32, 64}). Batched cases test the
//   `hammingDistanceBatch` protocol method (always all 4 blocks):
//
//   probe      : Fingerprint256
//   candidates : [Fingerprint256]   (length = batch_size)
//
// Output schema (batched):
//   distances  : [u32]              (length = batch_size)
//
// Per the kernel-learned-dispatch decision
//, batched output
// MUST equal sequential output byte-for-byte in at-rest
// little-endian canonical form. The conformance gate enforces
// this.

import Foundation
import GeniusLocusReference

public enum HammingPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "hamming",
        cookbookSection: "§8.2",
        referenceFile: "glref-swift-Hamming.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()

        // ----- Pair-at-a-time cases (unchanged from prior versions).
        let pairCount = 32
        for i in 0..<pairCount {
            let a = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                    block2: rng.next(), block3: rng.next())
            let b = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                    block2: rng.next(), block3: rng.next())

            // Cycle the blocks bitmask through {0b0001, 0b0011, 0b0111, 0b1111}.
            // Each cycle exercises a different block-restriction
            // pattern. Bit k of the mask means "include block k".
            let blocksBitmask: UInt8 = [0x1, 0x3, 0x7, 0xF][i % 4]
            let blocksSet = Self.bitmaskToBlocks(blocksBitmask)
            let distance = Hamming.distance(a, b, blocks: blocksSet)

            let inputs = JSONDict([
                ("a",              .string(Self.encodeFingerprint(a))),
                ("b",              .string(Self.encodeFingerprint(b))),
                ("blocks_bitmask", .string(HexCoding.u8(blocksBitmask))),
            ])
            let output = JSONDict([
                ("distance", .string(HexCoding.u32(UInt32(distance)))),
            ])

            let id = String(format: "case_%03d", i)
            let description = String(
                format: "blocks_bitmask 0x%01X, distance %d", blocksBitmask, distance)
            cases.append(VectorFile.Case(
                id: id, description: description,
                inputs: inputs, expectedOutput: output))
        }

        // ----- Batched cases (one per batch_size in batchedSizes).
        //
        // The batched API tests `SubstrateKernel.hammingDistanceBatch`,
        // which always uses all 4 blocks (no per-call mask). Output is
        // [Int] of distances in candidate order. Per the
        // kernel-learned-dispatch decision, this output MUST byte-equal
        // a pair-at-a-time loop in at-rest LE form.
        let kernel = KernelSelector.current()
        let batchedSizes = [0, 1, 2, 4, 8, 16, 32, 64]
        for (k, batchSize) in batchedSizes.enumerated() {
            let probe = Fingerprint256(block0: rng.next(), block1: rng.next(),
                                        block2: rng.next(), block3: rng.next())
            let candidates: [Fingerprint256] = (0..<batchSize).map { _ in
                Fingerprint256(block0: rng.next(), block1: rng.next(),
                               block2: rng.next(), block3: rng.next())
            }

            let distances = kernel.hammingDistanceBatch(
                probe: probe, candidates: candidates)

            let inputs = JSONDict([
                ("probe", .string(Self.encodeFingerprint(probe))),
                ("candidates", .array(
                    candidates.map { .string(Self.encodeFingerprint($0)) })),
            ])
            let output = JSONDict([
                ("distances", .array(
                    distances.map { .string(HexCoding.u32(UInt32($0))) })),
            ])

            let id = String(format: "case_%03d", pairCount + k)
            let description = String(
                format: "batched, batch_size %d, sum_distance %d",
                batchSize, distances.reduce(0, +))
            cases.append(VectorFile.Case(
                id: id, description: description,
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "hamming",
            cookbookSection: "§8.2",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-Hamming.swift"),
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
        // Batched cases have a `distances` array in expected_output.
        // Pair-at-a-time cases have a single `distance` scalar.
        if case .array = c.expectedOutput.get("distances") ?? .null {
            return validateBatchedCase(c, encoder: &encoder)
        }
        return validatePairCase(c, encoder: &encoder)
    }

    private static func validatePairCase(_ c: VectorFile.Case,
                                          encoder: inout CanonicalBinaryEncoder)
                                         -> ValidationResult.CaseResult {
        guard case .string(let aHex) = c.inputs.get("a") ?? .null,
              let a = parseFingerprint(aHex) else { return fail(c, "missing or malformed a") }
        guard case .string(let bHex) = c.inputs.get("b") ?? .null,
              let b = parseFingerprint(bHex) else { return fail(c, "missing or malformed b") }
        guard case .string(let maskHex) = c.inputs.get("blocks_bitmask") ?? .null,
              let mask = parseU8(maskHex) else { return fail(c, "missing or malformed blocks_bitmask") }

        let actual = UInt32(Hamming.distance(a, b, blocks: bitmaskToBlocks(mask)))

        guard case .string(let expHex) = c.expectedOutput.get("distance") ?? .null,
              let expected = parseU32(expHex) else {
            return fail(c, "missing or malformed expected distance")
        }

        encoder.writeU32(actual)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "distance mismatch: expected \(HexCoding.u32(expected)), got \(HexCoding.u32(actual))")
        }
    }

    private static func validateBatchedCase(_ c: VectorFile.Case,
                                             encoder: inout CanonicalBinaryEncoder)
                                            -> ValidationResult.CaseResult {
        guard case .string(let probeHex) = c.inputs.get("probe") ?? .null,
              let probe = parseFingerprint(probeHex) else {
            return fail(c, "missing or malformed probe")
        }
        guard case .array(let candArr) = c.inputs.get("candidates") ?? .null else {
            return fail(c, "missing candidates")
        }
        var candidates = [Fingerprint256]()
        candidates.reserveCapacity(candArr.count)
        for item in candArr {
            guard case .string(let s) = item, let fp = parseFingerprint(s) else {
                return fail(c, "malformed candidate")
            }
            candidates.append(fp)
        }

        guard case .array(let expArr) = c.expectedOutput.get("distances") ?? .null else {
            return fail(c, "missing expected distances")
        }
        var expected = [UInt32]()
        expected.reserveCapacity(expArr.count)
        for item in expArr {
            guard case .string(let s) = item, let v = parseU32(s) else {
                return fail(c, "malformed expected distance")
            }
            expected.append(v)
        }

        guard candidates.count == expected.count else {
            return fail(c, "length mismatch: \(candidates.count) candidates vs \(expected.count) expected")
        }

        let kernel = KernelSelector.current()
        let actualInts = kernel.hammingDistanceBatch(
            probe: probe, candidates: candidates)
        let actual = actualInts.map { UInt32($0) }

        // Canonical binary encoding: u32 LE length prefix + N u32 LE values.
        // Per the kernel-learned-dispatch decision, this byte stream must
        // exactly equal a sequential loop of pair-at-a-time u32 LE writes.
        encoder.writeU32(UInt32(actual.count))
        for v in actual { encoder.writeU32(v) }

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            let firstDiff = (0..<actual.count).first(where: { actual[$0] != expected[$0] }) ?? 0
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "batched distance mismatch at index \(firstDiff): expected \(HexCoding.u32(expected[firstDiff])), got \(HexCoding.u32(actual[firstDiff]))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        // Dispatch on which schema this case uses. Order MUST match
        // validateCase so generator and validator produce identical
        // canonical byte streams.
        if case .array(let arr) = output.get("distances") ?? .null {
            encoder.writeU32(UInt32(arr.count))
            for item in arr {
                guard case .string(let s) = item, let v = parseU32(s) else {
                    fatalError("batched distance element malformed")
                }
                encoder.writeU32(v)
            }
            return
        }

        guard case .string(let s) = output.get("distance") ?? .null,
              let v = parseU32(s) else {
            fatalError("expected_output missing or malformed distance")
        }
        encoder.writeU32(v)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    /// Bit k of `mask` set means "include block k" in the
    /// distance calculation.
    private static func bitmaskToBlocks(_ mask: UInt8) -> Set<Int> {
        var out = Set<Int>()
        for k in 0..<4 where (mask >> UInt8(k)) & 1 == 1 { out.insert(k) }
        return out
    }

    /// Hex-encode a Fingerprint256 as 64 lowercase chars (32
    /// bytes LE). Mirrors the Rust harness encoding so the JSON
    /// strings are byte-identical across languages.
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

    private static func parseU32(_ s: String) -> UInt32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var v: UInt32 = 0
        for (i, b) in bytes.enumerated() { v |= UInt32(b) << (i * 8) }
        return v
    }

    private static func parseU8(_ s: String) -> UInt8? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 1 else { return nil }
        return bytes[0]
    }
}
