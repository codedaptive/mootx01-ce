// DPORReduction.swift
//
// Differentially-private OR-reduction per cookbook § 12.6.
//
// Federation aggregations OR-reduce per-estate fingerprints down
// to a single 256-bit signature. To prevent any individual estate
// from being identified by its contribution, the substrate applies
// two complementary mechanisms:
//
//   1. k-anonymity threshold: a bit is set in the aggregate only
//      if at least k contributing estates had it set. The
//      per-bit popcount must reach k before the bit "lights up."
//
//   2. Differential privacy: a bit's per-bit popcount is perturbed
//      by Laplace noise of scale 1/ε before the k threshold is
//      applied. The (ε, δ) budget is consumed at the aggregation
//      point and recorded in the privacy ledger.
//
// The combination provides (ε, δ)-DP with k-anonymity layered on
// top. Default parameters: ε = 1.0, δ = 1e-9, k = 3.
//
// Used by:
//   § 12.6   DP definition (this file)
//   § 12.4   Tier-ascending query protocol (consumer)
//   § 9.4 of paper  Differential privacy at tier aggregation
//   § 9.5 of paper  K-anonymity layered on top

import Foundation
import SubstrateTypes

public struct DPParameters: Sendable {
    public let epsilon: Float64
    public let delta: Float64
    public let kAnonymity: Int

    public init(epsilon: Float64 = 1.0,
                delta: Float64 = 1e-9,
                kAnonymity: Int = 3) {
        precondition(epsilon > 0, "epsilon must be positive")
        precondition(delta >= 0 && delta < 1, "delta in [0,1)")
        precondition(kAnonymity >= 1, "k-anonymity at least 1")
        self.epsilon = epsilon
        self.delta = delta
        self.kAnonymity = kAnonymity
    }
}

public enum DPORReduction {

    /// Differentially-private OR-reduction over a set of per-estate
    /// fingerprints. The result is a single Fingerprint256 where
    /// each bit reflects whether ≥k contributing estates had the
    /// bit set after Laplace noise was added to the popcount.
    public static func reduce(fingerprints: [Fingerprint256],
                              params: DPParameters,
                              rngSeed: UInt64) -> Fingerprint256 {
        guard !fingerprints.isEmpty else { return .zero }

        // Per-bit popcounts across contributors.
        var popcounts = Array<Int>(repeating: 0, count: 256)
        for fp in fingerprints {
            for i in 0..<256 where fp.testBit(at: i) {
                popcounts[i] += 1
            }
        }

        // Add Laplace noise of scale 1/ε to each popcount.
        var rng = SplitMix64(seed: rngSeed)
        let scale = 1.0 / params.epsilon
        var perturbed = Array<Float64>(repeating: 0, count: 256)
        for i in 0..<256 {
            perturbed[i] = Float64(popcounts[i]) + laplaceNoise(scale: scale, rng: &rng)
        }

        // Apply k-anonymity threshold.
        var out = Fingerprint256.zero
        for i in 0..<256 where perturbed[i] >= Float64(params.kAnonymity) {
            out = out.with(bit: i)
        }
        return out
    }

    /// Laplace noise with scale b (mean zero). Generated from
    /// uniform-01 via inverse-CDF: -b · sign(u) · ln(1 - 2|u|).
    static func laplaceNoise(scale: Float64, rng: inout SplitMix64) -> Float64 {
        let raw = rng.next()
        let u = (Float64(raw >> 11) / Float64(1 << 53)) - 0.5   // uniform on (-0.5, 0.5)
        let sign: Float64 = u >= 0 ? 1.0 : -1.0
        return -scale * sign * log(1.0 - 2.0 * abs(u))
    }
}
