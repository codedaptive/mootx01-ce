// SimHashPrimitive.swift
//
// Worked example: SimHash primitive (cookbook § 3.6) under the
// test harness.
//
// Per primitive walkthrough (`docs/primitive-walkthrough-SimHash.md`):
//
// Input schema (pair-at-a-time cases, 32 of them):
//   input_vector_words : array of u64 (length 1 or 3 depending on block)
//   hyperplane_density : f64 (in (0, 1]; controls plane sparsity)
//   block_index        : u8 (0..3)
//   input_bit_length   : u32 (192 for block 0, 64 for blocks 1..3)
//   hyperplane_seed    : u64 (used to expand to 32-byte family seed)
//
// Output schema (pair):
//   block_value : u64
//
// Input schema (batched cases, 8 of them, one per batch_size in
//   {0, 1, 2, 4, 8, 16, 32, 64}). Batched cases test the
//   `simhashBlockBatch` protocol method: one family applied to
//   many input vectors. All inputs in a batched case share the
//   same family (block_index, hyperplane_seed, density,
//   input_bit_length); only the input_vector_words varies.
//
//   block_index              : u8
//   hyperplane_seed          : u64
//   hyperplane_density       : f64
//   input_bit_length         : u32
//   input_vector_words_batch : [[u64]]   (length = batch_size)
//
// Output schema (batched):
//   block_values : [u64]                 (length = batch_size)
//
// Per the kernel-learned-dispatch decision
// (DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17), batched output
// MUST equal sequential output byte-for-byte in at-rest
// little-endian canonical form. The conformance gate enforces
// this.

import Foundation
import GeniusLocusReference

public enum SimHashPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "simhash",
        cookbookSection: "§3.6",
        referenceFile: "glref-swift-SimHash.swift",
        generate: generate,
        validate: validate
    )

    // MARK: - Case generation

    /// Generate a deterministic case list from the seed. Same seed,
    /// same harness version ⇒ identical case set.
    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()

        // ----- Pair-at-a-time cases (unchanged from prior versions).
        let pairCount = 32
        for i in 0..<pairCount {
            let blockIndex = UInt8(i % 4)
            let inputBitLength: UInt32 = (blockIndex == 0) ? 192 : 64
            let inputWordCount = Int((inputBitLength + 63) / 64)
            var inputWords = [UInt64]()
            for _ in 0..<inputWordCount {
                inputWords.append(rng.next())
            }
            let hyperplaneSeed = rng.next()
            let density: Double = 1.0  // dense hyperplanes for now

            let blockValue = referenceSimHash(
                inputWords: inputWords,
                hyperplaneSeed: hyperplaneSeed,
                blockIndex: blockIndex,
                inputBitLength: Int(inputBitLength),
                density: density
            )

            // Inputs payload (canonical JSON form).
            let inputsDict = JSONDict([
                ("block_index",         .integer(Int64(blockIndex))),
                ("hyperplane_density",  .string(HexCoding.f64(density))),
                ("hyperplane_seed",     .string(HexCoding.u64(hyperplaneSeed))),
                ("input_bit_length",    .integer(Int64(inputBitLength))),
                ("input_vector_words",  .array(inputWords.map { .string(HexCoding.u64($0)) })),
            ])
            let outputDict = JSONDict([
                ("block_value", .string(HexCoding.u64(blockValue))),
            ])

            let id = String(format: "case_%03d", i)
            cases.append(VectorFile.Case(
                id: id,
                description: "block \(blockIndex), input bit length \(inputBitLength), density \(density)",
                inputs: inputsDict,
                expectedOutput: outputDict
            ))
        }

        // ----- Batched cases (one per batch_size in batchedSizes).
        //
        // Each batched case fixes one family (block_index,
        // hyperplane_seed, density, input_bit_length) and feeds N
        // input vectors of identical word_count through
        // simhashBlockBatch. Output is [UInt64] of block values.
        let kernel = KernelSelector.current()
        let batchedSizes = [0, 1, 2, 4, 8, 16, 32, 64]
        for (k, batchSize) in batchedSizes.enumerated() {
            let blockIndex = UInt8(k % 4)
            let inputBitLength: UInt32 = (blockIndex == 0) ? 192 : 64
            let inputWordCount = Int((inputBitLength + 63) / 64)
            let hyperplaneSeed = rng.next()
            let density: Double = 1.0

            var inputBatch = [[UInt64]]()
            inputBatch.reserveCapacity(batchSize)
            for _ in 0..<batchSize {
                var words = [UInt64]()
                words.reserveCapacity(inputWordCount)
                for _ in 0..<inputWordCount {
                    words.append(rng.next())
                }
                inputBatch.append(words)
            }

            let seedBytes = Self.expandSeedTo32(hyperplaneSeed)
            let family = HyperplaneFamily.generate(
                seed: seedBytes,
                blockIndex: Int(blockIndex),
                inputBitLength: Int(inputBitLength),
                density: density)

            let blockValues = kernel.simhashBlockBatch(
                inputs: inputBatch, family: family)

            let inputsDict = JSONDict([
                ("block_index",        .integer(Int64(blockIndex))),
                ("hyperplane_density", .string(HexCoding.f64(density))),
                ("hyperplane_seed",    .string(HexCoding.u64(hyperplaneSeed))),
                ("input_bit_length",   .integer(Int64(inputBitLength))),
                ("input_vector_words_batch", .array(
                    inputBatch.map { words in
                        .array(words.map { .string(HexCoding.u64($0)) })
                    })),
            ])
            let outputDict = JSONDict([
                ("block_values", .array(
                    blockValues.map { .string(HexCoding.u64($0)) })),
            ])

            let id = String(format: "case_%03d", pairCount + k)
            cases.append(VectorFile.Case(
                id: id,
                description: "batched, block \(blockIndex), batch_size \(batchSize), input bit length \(inputBitLength)",
                inputs: inputsDict,
                expectedOutput: outputDict
            ))
        }

        // Compute output CRC.
        var encoder = CanonicalBinaryEncoder()
        for c in cases {
            encodeOutput(c.expectedOutput, into: &encoder)
        }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "simhash",
            cookbookSection: "§3.6",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-SimHash.swift"),
            seed: seed,
            generatedAt: isoTimestamp(),
            outputCrc32: crc,
            cases: cases
        )
    }

    // MARK: - Validation

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()

        for c in file.cases {
            // Dispatch on schema: batched cases have `block_values` array.
            if case .array = c.expectedOutput.get("block_values") ?? .null {
                let (result, actualBatch) = validateBatchedCase(c)
                caseResults.append(result)
                // Canonical binary encoding: u32 LE length prefix + N u64 LE values.
                encoder.writeU32(UInt32(actualBatch.count))
                for v in actualBatch { encoder.writeU64(v) }
                continue
            }

            // Pair-at-a-time path (unchanged).
            // Parse inputs.
            guard case .integer(let blockIdx)   = c.inputs.get("block_index")  ?? .null,
                  case .string(let densityHex)  = c.inputs.get("hyperplane_density") ?? .null,
                  case .string(let seedHex)     = c.inputs.get("hyperplane_seed") ?? .null,
                  case .integer(let inputBits)  = c.inputs.get("input_bit_length") ?? .null,
                  case .array(let wordVals)     = c.inputs.get("input_vector_words") ?? .null else {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "malformed inputs"))
                continue
            }
            let inputWords: [UInt64]
            do {
                inputWords = try wordVals.map { v -> UInt64 in
                    guard case .string(let h) = v else {
                        throw HexCodingError.invalidCharacter(String(describing: v))
                    }
                    let b = try HexCoding.decode(h)
                    guard b.count == 8 else {
                        throw HexCodingError.invalidCharacter(h)
                    }
                    return b.enumerated().reduce(UInt64(0)) {
                        $0 | (UInt64($1.element) << ($1.offset * 8))
                    }
                }
            } catch {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "malformed input_vector_words: \(error)"))
                continue
            }
            let densityBytes: [UInt8]
            let seedBytes: [UInt8]
            do {
                densityBytes = try HexCoding.decode(densityHex)
                seedBytes = try HexCoding.decode(seedHex)
            } catch {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "malformed hex: \(error)"))
                continue
            }
            guard densityBytes.count == 8, seedBytes.count == 8 else {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "wrong byte width on density or seed"))
                continue
            }
            let densityBits = densityBytes.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << ($1.offset * 8))
            }
            let density = Double(bitPattern: densityBits)
            let hyperplaneSeed = seedBytes.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << ($1.offset * 8))
            }

            // Run the reference.
            let actual = referenceSimHash(
                inputWords: inputWords,
                hyperplaneSeed: hyperplaneSeed,
                blockIndex: UInt8(blockIdx),
                inputBitLength: Int(inputBits),
                density: density
            )

            // Compare.
            guard case .string(let expHex) = c.expectedOutput.get("block_value") ?? .null else {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "expected_output missing block_value"))
                continue
            }
            let expBytes = (try? HexCoding.decode(expHex)) ?? []
            guard expBytes.count == 8 else {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "expected_output.block_value not 8 bytes"))
                continue
            }
            let expected = expBytes.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << ($1.offset * 8))
            }

            if actual == expected {
                caseResults.append(.init(id: c.id, passed: true, diagnostic: nil))
            } else {
                caseResults.append(.init(id: c.id, passed: false,
                                          diagnostic: "block_value mismatch: expected \(HexCoding.u64(expected)), got \(HexCoding.u64(actual))"))
            }

            // Feed the canonical output into the encoder for CRC re-check.
            encodeOutputForReference(actual: actual, into: &encoder)
        }

        let crcActual = CRC32.compute(encoder.bytes)
        let allCasesPassed = caseResults.allSatisfy { $0.passed }
        let crcOk = crcActual == file.outputCrc32

        return ValidationResult(
            passed: allCasesPassed && crcOk,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual
        )
    }

    /// Validate one batched case. Returns the case result and the
    /// actual computed batch (the caller feeds it into the
    /// canonical encoder for CRC).
    private static func validateBatchedCase(_ c: VectorFile.Case) -> (ValidationResult.CaseResult, [UInt64]) {
        // Family fields.
        guard case .integer(let blockIdx)  = c.inputs.get("block_index")  ?? .null,
              case .string(let densityHex) = c.inputs.get("hyperplane_density") ?? .null,
              case .string(let seedHex)    = c.inputs.get("hyperplane_seed") ?? .null,
              case .integer(let inputBits) = c.inputs.get("input_bit_length") ?? .null,
              case .array(let batchVals)   = c.inputs.get("input_vector_words_batch") ?? .null else {
            return (.init(id: c.id, passed: false,
                          diagnostic: "malformed batched inputs"), [])
        }
        let densityBytes: [UInt8]
        let seedBytes: [UInt8]
        do {
            densityBytes = try HexCoding.decode(densityHex)
            seedBytes = try HexCoding.decode(seedHex)
        } catch {
            return (.init(id: c.id, passed: false,
                          diagnostic: "malformed hex: \(error)"), [])
        }
        guard densityBytes.count == 8, seedBytes.count == 8 else {
            return (.init(id: c.id, passed: false,
                          diagnostic: "wrong byte width on density or seed"), [])
        }
        let densityBits = densityBytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        let density = Double(bitPattern: densityBits)
        let hyperplaneSeed = seedBytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }

        // Parse the input batch.
        var inputBatch = [[UInt64]]()
        inputBatch.reserveCapacity(batchVals.count)
        for wordsVal in batchVals {
            guard case .array(let warr) = wordsVal else {
                return (.init(id: c.id, passed: false,
                              diagnostic: "batched input element not an array"), [])
            }
            var words = [UInt64]()
            words.reserveCapacity(warr.count)
            for v in warr {
                guard case .string(let h) = v else {
                    return (.init(id: c.id, passed: false,
                                  diagnostic: "batched input word not a string"), [])
                }
                let b = (try? HexCoding.decode(h)) ?? []
                guard b.count == 8 else {
                    return (.init(id: c.id, passed: false,
                                  diagnostic: "malformed batched input word"), [])
                }
                let w = b.enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << ($1.offset * 8))
                }
                words.append(w)
            }
            inputBatch.append(words)
        }

        // Parse expected output.
        guard case .array(let expArr) = c.expectedOutput.get("block_values") ?? .null else {
            return (.init(id: c.id, passed: false,
                          diagnostic: "missing expected block_values"), [])
        }
        var expected = [UInt64]()
        expected.reserveCapacity(expArr.count)
        for v in expArr {
            guard case .string(let h) = v else {
                return (.init(id: c.id, passed: false,
                              diagnostic: "expected block_value not a string"), [])
            }
            let b = (try? HexCoding.decode(h)) ?? []
            guard b.count == 8 else {
                return (.init(id: c.id, passed: false,
                              diagnostic: "malformed expected block_value"), [])
            }
            expected.append(b.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << ($1.offset * 8))
            })
        }

        guard inputBatch.count == expected.count else {
            return (.init(id: c.id, passed: false,
                          diagnostic: "length mismatch: \(inputBatch.count) inputs vs \(expected.count) expected"), [])
        }

        // Build family once, dispatch through trait's batched method.
        // Must expand the 8-byte hyperplane_seed to the 32-byte
        // family seed via the same SplitMix avalanche the gen path uses.
        let expandedSeed = Self.expandSeedTo32(hyperplaneSeed)
        let family = HyperplaneFamily.generate(
            seed: expandedSeed,
            blockIndex: Int(blockIdx),
            inputBitLength: Int(inputBits),
            density: density)
        let kernel = KernelSelector.current()
        let actual = kernel.simhashBlockBatch(
            inputs: inputBatch, family: family)

        if actual == expected {
            return (.init(id: c.id, passed: true, diagnostic: nil), actual)
        } else {
            let firstDiff = (0..<actual.count).first(where: { actual[$0] != expected[$0] }) ?? 0
            return (.init(id: c.id, passed: false,
                          diagnostic: "batched block_value mismatch at index \(firstDiff): expected \(HexCoding.u64(expected[firstDiff])), got \(HexCoding.u64(actual[firstDiff]))"), actual)
        }
    }

    // MARK: - Output encoding (canonical binary)

    /// Encode a SimHash expected-output dict into the canonical
    /// binary stream. Used during generation (encoding the
    /// expected output) and during validation (encoding the
    /// actual output for CRC re-check).
    private static func encodeOutput(_ output: JSONDict,
                                      into encoder: inout CanonicalBinaryEncoder) {
        // Dispatch on schema. Order MUST match validate so generator
        // and validator produce identical canonical byte streams.
        if case .array(let arr) = output.get("block_values") ?? .null {
            encoder.writeU32(UInt32(arr.count))
            for item in arr {
                guard case .string(let hex) = item else {
                    preconditionFailure("block_values element not a string")
                }
                let bytes = (try? HexCoding.decode(hex)) ?? []
                precondition(bytes.count == 8, "batched block_value must be 8 bytes")
                let v = bytes.enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << ($1.offset * 8))
                }
                encoder.writeU64(v)
            }
            return
        }

        // SimHash output schema (pair): { block_value: u64 }
        guard case .string(let hex) = output.get("block_value") ?? .null else {
            preconditionFailure("expected_output missing block_value")
        }
        let bytes = (try? HexCoding.decode(hex)) ?? []
        precondition(bytes.count == 8, "block_value must be 8 bytes")
        let v = bytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        encoder.writeU64(v)
    }

    private static func encodeOutputForReference(actual: UInt64,
                                                  into encoder: inout CanonicalBinaryEncoder) {
        encoder.writeU64(actual)
    }

    // MARK: - Reference (stub)
    //
    // The shipping reference lives at
    // `substrate_reference/GeniusLocusReference/glref-swift-SimHash.swift` and
    // depends on Fingerprint256 + HyperplaneFamily. For this
    // first harness pass we provide a self-contained stub that
    // produces deterministic output for the harness plumbing test;
    // the next pass replaces the stub with a direct call into the
    // real reference once it's wired in as a package dependency.

    private static func referenceSimHash(inputWords: [UInt64],
                                          hyperplaneSeed: UInt64,
                                          blockIndex: UInt8,
                                          inputBitLength: Int,
                                          density: Double) -> UInt64 {
        // Real-reference call. The reference takes a
        // `HyperplaneFamily`, not a bare seed; we expand the
        // u64 harness seed to a 32-byte byte array via SplitMix-
        // style avalanche (matching the Rust mirror in
        // pairing.rs::expand_seed_to_32) before constructing the
        // family.
        let seedBytes = Self.expandSeedTo32(hyperplaneSeed)
        let family = HyperplaneFamily.generate(
            seed: seedBytes,
            blockIndex: Int(blockIndex),
            inputBitLength: inputBitLength,
            density: density)
        return SimHash.block(over: inputWords, family: family)
    }

    /// Expand a 64-bit seed to 32 bytes via 4 rounds of
    /// SplitMix64-style avalanche. Same construction as the
    /// Rust harness's `expand_seed_to_32` (primitives/simhash.rs)
    /// and the reference's `expandSeedTo32`
    /// (PairingHandshake.swift); duplicated locally so the
    /// harness does not depend on a non-public helper.
    private static func expandSeedTo32(_ seed: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        var s = seed
        for i in 0..<4 {
            s = s &+ 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            for j in 0..<8 {
                out[i * 8 + j] = UInt8((z >> (j * 8)) & 0xFF)
            }
        }
        return out
    }

    // ============================================================
    // Historical reference stub (Path 1, kept for documentation)
    // ============================================================
    //
    // The stub below was used to validate the harness conformance
    // machinery before the real references compiled. It produced
    // CRC 0xcafd725b for seed 0xCAFEBABEDEADBEEF. Replaced above
    // by the real-reference call.
    //
    //   var rng = SplitMix64(seed: hyperplaneSeed ^ UInt64(blockIndex) ^ UInt64(inputBitLength))
    //   _ = density
    //   var result: UInt64 = 0
    //   for word in inputWords { result ^= word &* rng.next() }
    //   return result


    // MARK: - Helpers

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
