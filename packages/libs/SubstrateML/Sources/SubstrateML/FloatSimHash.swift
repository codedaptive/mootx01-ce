// FloatSimHash.swift
//
// Float-input SimHash for external embedding providers.
//
// SubstrateLib's main SimHash (SimHash.swift) operates on bitmap
// subhashes from substrate-native feature extraction. External
// embedding providers (MiniLM, BERT, EmbeddingGemma) produce
// dense float vectors; this primitive projects those into the
// canonical 256-bit Fingerprint256 form so similarity comparisons
// work across all providers.
//
// Algorithm:
//   - Generate 256 random hyperplanes from a deterministic seed.
//   - For each bit k in 0..<256: output_bit_k = sign(<v, h_k>).
//   - Pack into four UInt64 blocks per Fingerprint256.
//
// The hyperplane generation is seeded so the same seed produces
// the same projection across runs and across processes; this is
// required for storage and retrieval to round-trip.
//
// Cosine similarity is preserved approximately: the Hamming
// distance between two FloatSimHash outputs is proportional to
// the angular distance between the input vectors. See cookbook
// section 3.6 for the proof.

import Foundation
import SubstrateTypes

public enum FloatSimHash {

    /// Project a float vector to a 256-bit Fingerprint256 via
    /// signed hyperplane projection.
    ///
    /// - Parameters:
    ///   - vector: dense input vector (any dimension; 384 for
    ///     MiniLM, 768 for BERT base, 768 for EmbeddingGemma 300M).
    ///   - seed: deterministic seed for hyperplane generation. Same
    ///     seed always produces the same projection. Different
    ///     providers should use different seeds so their fingerprints
    ///     are model-tagged independent of vector content.
    public static func project(vector: [Float], seed: UInt64) -> Fingerprint256 {
        guard !vector.isEmpty else {
            return Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
        }
        let dim = vector.count
        var blocks: [UInt64] = [0, 0, 0, 0]
        var rng = SplitMix64(seed: seed)

        for bitIndex in 0..<256 {
            // Generate one hyperplane (dim floats) deterministically.
            var sum: Float = 0
            for floatIndex in 0..<dim {
                // Box-Muller from two uniforms gives a standard
                // Gaussian; the sign of <v, h> is what we keep,
                // so Gaussian-vs-uniform-vs-Rademacher all work.
                // Rademacher (+1/-1) is fastest.
                let u = rng.next()
                let plane: Float = (u & 1) == 0 ? -1 : 1
                sum += plane * vector[floatIndex]
            }
            if sum > 0 {
                let blockIndex = bitIndex / 64
                let bitInBlock = bitIndex % 64
                blocks[blockIndex] |= (UInt64(1) << bitInBlock)
            }
        }
        return Fingerprint256(
            block0: blocks[0],
            block1: blocks[1],
            block2: blocks[2],
            block3: blocks[3]
        )
    }
}

