// Lib_or_reduce.swift
//
// Lib-side conformance CRC for the `or_reduce` primitive (cookbook
// §8.5). Computes the canonical CRC by calling the SHIPPING libs —
// Uses `ORReduce.reduce` per batch — no kernel instance needed for the
// lib-side CRC because cross-kernel agreement is handled by subsystem 2.
//
// Byte mechanism mirrors Harness ORReducePrimitive.validateCase
// exactly. The vector file mixes two case shapes; we dispatch on the
// presence of a `reduced_batch` array in expected_output, identical
// to the harness's validateCase:
//
//   Pair case   — inputs.fingerprints : .array of 64-char LE hex.
//                 Decode each into a Fingerprint256, call
//                 ORReduce.reduce, write the result as 4× writeU64.
//
//   Batched case — inputs.batches : .array of .array of hex. Decode
//                 into [[Fingerprint256]], call
//                 kernel.orReduceBatch(batches:), then write a u32 LE
//                 count prefix followed by each result fingerprint as
//                 4× writeU64 — matching the harness's batched
//                 encoder ordering.
//
// Kernel selection: the harness resolves the batched path through
// `KernelSelector.current()` (glref kernel) under the kind set by the
// `--kernel` flag, defaulting to scalar. We resolve the SHIPPING
// kernel from that same selected kind by mapping the rawValue across
// the two (String-backed) KernelKind enums, so lib and glref run the
// same backend and the byte streams are comparable.

import Foundation
import Harness
import SubstrateTypes

enum Lib_or_reduce {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // Dispatch on schema, identical to the harness's
            // validateCase: a `reduced_batch` array in expected_output
            // marks a batched case; otherwise it is a pair case.
            if case .array = c.expectedOutput.get("reduced_batch") ?? .null {
                orReduceEncodeBatchedCase(c, enc: &enc)
            } else {
                orReduceEncodePairCase(c, enc: &enc)
            }
        }
        return CRC32.compute(enc.bytes)
    }

    /// Pair-at-a-time case: decode the `fingerprints` list, call the
    /// shipping `ORReduce.reduce`, write the result as 4× writeU64.
    /// On malformed input we skip without writing, mirroring the
    /// harness `guard ... else { return fail }` (failed cases write no
    /// canonical bytes).
    private static func orReduceEncodePairCase(_ c: VectorFile.Case,
                                               enc: inout CanonicalBinaryEncoder) {
        guard case .array(let fpArr) = c.inputs.get("fingerprints") ?? .null else { return }
        var cohort = [Fingerprint256]()
        cohort.reserveCapacity(fpArr.count)
        for v in fpArr {
            guard case .string(let hex) = v,
                  let fp = orReduceParseFingerprint(hex) else { return }
            cohort.append(fp)
        }
        // Shipping API: SubstrateTypes.ORReduce.reduce(_:) over a
        // Sequence of Fingerprint256. Returns Fingerprint256.zero for
        // empty input (the identity), symbol-equivalent to glref.
        let reduced = ORReduce.reduce(cohort)
        orReduceWriteFingerprint(reduced, enc: &enc)
    }

    /// Batched case: decode the `batches` list-of-lists, call the
    /// shipping kernel's `orReduceBatch`, then write a u32 LE count
    /// prefix followed by each result fingerprint as 4× writeU64.
    /// Order matches Harness ORReducePrimitive.validateBatchedCase.
    private static func orReduceEncodeBatchedCase(_ c: VectorFile.Case,
                                                  enc: inout CanonicalBinaryEncoder) {
        guard case .array(let outerArr) = c.inputs.get("batches") ?? .null else { return }
        var batches = [[Fingerprint256]]()
        batches.reserveCapacity(outerArr.count)
        for cohortVal in outerArr {
            guard case .array(let cohortArr) = cohortVal else { return }
            var cohort = [Fingerprint256]()
            cohort.reserveCapacity(cohortArr.count)
            for v in cohortArr {
                guard case .string(let hex) = v,
                      let fp = orReduceParseFingerprint(hex) else { return }
                cohort.append(fp)
            }
            batches.append(cohort)
        }
        // Batched output must equal sequential output byte for byte
        // (DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17), so the canonical
        // scalar value is just ORReduce.reduce per batch — no kernel
        // instance needed for the lib-side CRC. (Cross-kernel batched
        // agreement is subsystem 2, handled separately.)
        let reducedBatch = batches.map { ORReduce.reduce($0) }
        // u32 LE length prefix + N Fingerprint256 (each 4 u64 LE).
        enc.writeU32(UInt32(reducedBatch.count))
        for fp in reducedBatch { orReduceWriteFingerprint(fp, enc: &enc) }
    }

    /// Write a Fingerprint256 as four little-endian u64 blocks, in
    /// block0..block3 order — identical to the harness writeFingerprint.
    private static func orReduceWriteFingerprint(_ fp: Fingerprint256,
                                                 enc: inout CanonicalBinaryEncoder) {
        enc.writeU64(fp.block0)
        enc.writeU64(fp.block1)
        enc.writeU64(fp.block2)
        enc.writeU64(fp.block3)
    }

    /// Decode a 64-char little-endian hex string into a Fingerprint256.
    /// Mirrors the harness `parseFingerprint`: 32 bytes, block i built
    /// from bytes [i*8, i*8+8) little-endian. Returns nil on wrong
    /// length / malformed hex.
    private static func orReduceParseFingerprint(_ s: String) -> Fingerprint256? {
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
