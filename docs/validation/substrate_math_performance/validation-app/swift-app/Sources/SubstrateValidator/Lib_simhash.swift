// Lib_simhash.swift
//
// Lib-side conformance CRC for the `simhash` primitive (cookbook §3.6).
// Computes the canonical CRC by calling the SHIPPING libs
// (SubstrateTypes.HyperplaneFamily + SubstrateTypes.SimHash for the
// pair path, SubstrateKernel.ScalarKernel.simhashBlockBatch for the
// batched path), NOT the glref reference, so the validator can report
// lib-vs-glref drift on the SimHash projection chain.
//
// Byte mechanism mirrors Harness SimHashPrimitive.validate exactly:
//
//   Pair-at-a-time case (output schema { block_value: u64 }):
//     decode input_vector_words[] (each a 16-char LE-hex u64),
//     hyperplane_density (8-byte LE-hex f64 bit pattern),
//     hyperplane_seed (8-byte LE-hex u64), block_index (integer),
//     input_bit_length (integer); expand the 8-byte seed to a
//     32-byte family seed via the SplitMix64 avalanche; build the
//     HyperplaneFamily; project via SimHash.block; encode one
//     u64 LE (encoder.writeU64) — matches harness
//     encodeOutputForReference.
//
//   Batched case (output schema { block_values: [u64] }, detected by
//     an `input_vector_words_batch` array): same family construction,
//     dispatch the input batch through the scalar kernel's
//     simhashBlockBatch, then encode a u32 LE length prefix followed
//     by N u64 LE values — matches the batched branch of harness
//     validate (encoder.writeU32(count) + writeU64 per value).
//
// The seed→hyperplane→projection chain is byte-sensitive; the family
// construction (32-byte expanded seed, density, block index, input
// bit length) is replicated against the shipping HyperplaneFamily
// type identically to the harness so the lib-side CRC matches the
// committed outputCrc32 when lib and glref agree.
//
// The canonical lib path uses the SCALAR kernel: the harness default
// (KernelSelector defaults to .scalar) is the scalar reference, and
// the scalar reference is what the committed vectors encode.

import Foundation
import Harness
import SubstrateTypes
import SubstrateKernel

enum Lib_simhash {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        // Scalar reference kernel: matches the harness default kernel
        // (.scalar) under which the committed vectors were generated.
        let kernel = ScalarKernel()

        for c in file.cases {
            // Dispatch on schema, identical to harness validate():
            // batched cases carry a `block_values` array on output.
            if case .array = c.expectedOutput.get("block_values") ?? .null {
                let batch = shBatchedBlocks(c, kernel: kernel)
                // Canonical batched encoding: u32 LE length prefix
                // then N u64 LE values (harness validate batched branch).
                enc.writeU32(UInt32(batch.count))
                for v in batch { enc.writeU64(v) }
                continue
            }

            // Pair-at-a-time path.
            guard let block = shPairBlock(c) else { continue }
            // Canonical pair encoding: one u64 LE per case
            // (harness encodeOutputForReference).
            enc.writeU64(block)
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Pair-at-a-time

    /// Compute one SimHash block for a pair case by constructing the
    /// shipping HyperplaneFamily from the case's seed/density/block/
    /// bit-length fields and projecting the input vector through
    /// SubstrateTypes.SimHash.block. Returns nil on malformed input.
    private static func shPairBlock(_ c: VectorFile.Case) -> UInt64? {
        guard case .integer(let blockIdx)  = c.inputs.get("block_index") ?? .null,
              case .string(let densityHex) = c.inputs.get("hyperplane_density") ?? .null,
              case .string(let seedHex)    = c.inputs.get("hyperplane_seed") ?? .null,
              case .integer(let inputBits) = c.inputs.get("input_bit_length") ?? .null,
              case .array(let wordVals)    = c.inputs.get("input_vector_words") ?? .null,
              let density = shParseF64(densityHex),
              let seed = shParseU64(seedHex)
        else { return nil }

        var inputWords = [UInt64]()
        inputWords.reserveCapacity(wordVals.count)
        for v in wordVals {
            guard case .string(let h) = v, let w = shParseU64(h) else { return nil }
            inputWords.append(w)
        }

        let family = shFamily(seed: seed,
                              blockIndex: Int(blockIdx),
                              inputBitLength: Int(inputBits),
                              density: density)
        // Shipping projection: SubstrateTypes.SimHash.block(over:family:).
        return SimHash.block(over: inputWords, family: family)
    }

    // MARK: - Batched

    /// Compute the SimHash block values for a batched case by building
    /// the single shared shipping HyperplaneFamily and dispatching the
    /// input batch through the scalar kernel's simhashBlockBatch.
    /// Returns an empty batch on malformed input.
    private static func shBatchedBlocks(_ c: VectorFile.Case,
                                        kernel: ScalarKernel) -> [UInt64] {
        guard case .integer(let blockIdx)  = c.inputs.get("block_index") ?? .null,
              case .string(let densityHex) = c.inputs.get("hyperplane_density") ?? .null,
              case .string(let seedHex)    = c.inputs.get("hyperplane_seed") ?? .null,
              case .integer(let inputBits) = c.inputs.get("input_bit_length") ?? .null,
              case .array(let batchVals)   = c.inputs.get("input_vector_words_batch") ?? .null,
              let density = shParseF64(densityHex),
              let seed = shParseU64(seedHex)
        else { return [] }

        var inputBatch = [[UInt64]]()
        inputBatch.reserveCapacity(batchVals.count)
        for wordsVal in batchVals {
            guard case .array(let warr) = wordsVal else { return [] }
            var words = [UInt64]()
            words.reserveCapacity(warr.count)
            for v in warr {
                guard case .string(let h) = v, let w = shParseU64(h) else { return [] }
                words.append(w)
            }
            inputBatch.append(words)
        }

        let family = shFamily(seed: seed,
                              blockIndex: Int(blockIdx),
                              inputBitLength: Int(inputBits),
                              density: density)
        // Shipping batched dispatch: SubstrateKernel scalar kernel.
        return kernel.simhashBlockBatch(inputs: inputBatch, family: family)
    }

    // MARK: - Family construction

    /// Build the shipping HyperplaneFamily from the 8-byte harness
    /// seed and the family parameters. The 8-byte seed is expanded to
    /// the 32-byte family seed via the SplitMix64 avalanche, then
    /// SubstrateTypes.HyperplaneFamily.generate produces the 64-plane
    /// family — byte-identical to the harness validate() construction.
    private static func shFamily(seed: UInt64,
                                 blockIndex: Int,
                                 inputBitLength: Int,
                                 density: Double) -> HyperplaneFamily {
        let seedBytes = shExpandSeedTo32(seed)
        return HyperplaneFamily.generate(
            seed: seedBytes,
            blockIndex: blockIndex,
            inputBitLength: inputBitLength,
            density: density)
    }

    /// Expand a 64-bit seed to 32 bytes via 4 rounds of SplitMix64
    /// avalanche. Mirrors the harness SimHashPrimitive.expandSeedTo32
    /// (and the Rust expand_seed_to_32) byte-for-byte; the family seed
    /// is the load-bearing input to the whole projection chain.
    private static func shExpandSeedTo32(_ seed: UInt64) -> [UInt8] {
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

    // MARK: - Hex decode (little-endian)

    /// Decode a 16-char little-endian hex string into a u64. Mirrors
    /// the harness: 8 bytes, byte i contributes bits [i*8, i*8+8).
    private static func shParseU64(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (i * 8) }
        return v
    }

    /// Decode a 16-char little-endian hex string into an f64 via its
    /// IEEE-754 bit pattern. Mirrors the harness density decode:
    /// little-endian u64 bit pattern, then Double(bitPattern:).
    private static func shParseF64(_ s: String) -> Double? {
        guard let bits = shParseU64(s) else { return nil }
        return Double(bitPattern: bits)
    }
}
