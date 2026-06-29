// FloatSimHash.swift
//
// Float-input SimHash for external embedding providers.
//
// SubstrateTypes's SimHash (SimHash.swift) operates on bitmap
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
import SubstrateKernel

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
        // Single canonical leaf: project routes through the SubstrateKernel
        // dispatch op (SUBSTRATEKERNEL_SPEC § 5.4) rather than an inline loop.
        // `planes(seed:dim:)` materializes the ±1 hyperplane set; the kernel
        // applies it (pure signed-sum-and-sign). The platform kernel is selected
        // once and cached — re-selecting per call would re-run backend detection
        // and telemetry on the hot encode path. A SIMD float backend (1.1) drops
        // in at the kernel with no change to this call site.
        return Self.dispatchKernel.floatSimHashProject(
            vector: vector,
            planes: planes(seed: seed, dim: vector.count))
    }

    /// The platform kernel, selected once and reused. On aarch64 this is
    /// `SimdKernel`, which inherits the scalar `floatSimHashProject` reference
    /// until the 1.1 SIMD float backend lands and overrides it.
    private static let dispatchKernel: any SubstrateKernel =
        PortableKernel.kernelForCurrentPlatform()

    /// Materialize the ±1 hyperplane set this projection uses for `dim`, as a
    /// `FloatSimHashPlanes` for the SubstrateKernel dispatch op
    /// `floatSimHashProject(vector:planes:)` (SUBSTRATEKERNEL_SPEC § 5.4).
    ///
    /// The planes are generated in the SAME SplitMix64 draw order `project`
    /// consumes them — 256 hyperplanes outer, `dim` coordinates inner — so the
    /// kernel op fed these planes reproduces `project(vector:seed:)` bit for
    /// bit. A sign bit is set when the draw's low bit is 1, i.e. plane = +1,
    /// matching `project`'s `(u & 1) == 0 ? -1 : 1`.
    ///
    /// Deterministic and seed-immutable: callers cache the result per
    /// (seed, dim) and reuse it across every projection under that seed.
    public static func planes(seed: UInt64, dim: Int) -> FloatSimHashPlanes {
        precondition(dim >= 0, "dim must be non-negative")
        let total = 256 * dim
        var words = [UInt64](repeating: 0, count: (total + 63) / 64)
        var rng = SplitMix64(seed: seed)
        var bitIndex = 0
        for _ in 0..<256 {
            for _ in 0..<dim {
                let u = rng.next()
                if (u & 1) == 1 {
                    words[bitIndex >> 6] |= (UInt64(1) << UInt64(bitIndex & 63))
                }
                bitIndex += 1
            }
        }
        return FloatSimHashPlanes(dim: dim, signBits: words)
    }
}

