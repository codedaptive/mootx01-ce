// CompositeDistance.swift
//
// Composite distance per cookbook § 8.4.
//
// The substrate's primary retrieval distance combines the two
// coordinate systems:
//
//   d(a, b) = alpha_lattice * lattice_distance(a, b)
//           + alpha_fingerprint * (hamming_distance(a, b) / 256)
//
// Both component distances are normalized to [0, 1]; the
// composite is therefore in [0, 1] when
// alpha_lattice + alpha_fingerprint = 1.
//
// The weights are learned per-user-per-primitive via Bradley-
// Terry online updates on RecallTrace feedback (§ 8.12). Default
// at estate creation: alpha_lattice = 0.5, alpha_fingerprint = 0.5.
//
// Compatible-seed scope: two rows' fingerprints are comparable
// only under a common hyperplane family. Within-estate
// comparisons always work. Cross-estate comparisons require a
// federation pairing handshake (§ 12.2) that establishes a
// shared `H_shared_<scope>` family. If `compatibleSeedScope` is
// false, the fingerprint contribution is dropped and the
// composite collapses to the lattice term, NOT renormalized;
// the cookbook's intent is that cross-perimeter callers see a
// proportionally smaller "distance" because the only available
// coordinate is the lattice one.
//
// Cookbook reference: § 8.4.

import Foundation
import SubstrateTypes

public enum CompositeDistance {

    public static let defaultAlphaLattice: Double = 0.5
    public static let defaultAlphaFingerprint: Double = 0.5

    public static let fingerprintTotalBits: Int = 256

    /// Composite distance between two rows.
    ///
    /// Both component distances must be in [0, 1]; callers that pass
    /// out-of-range values will trap. `latticeDistance` must satisfy
    /// 0 ≤ d ≤ 1 (guaranteed by `UDCTreeDistance` and `WikidataGraphDistance`
    /// after the LatticeDistance normalization fix). `fingerprintHammingDistance`
    /// must not exceed `fingerprintTotalBits` (256); callers that derive it
    /// from `SimHash.hammingDistance` satisfy this by construction.
    public static func distance(
        latticeDistance: Double,
        fingerprintHammingDistance: Int,
        alphaLattice: Double = defaultAlphaLattice,
        alphaFingerprint: Double = defaultAlphaFingerprint,
        compatibleSeedScope: Bool = true
    ) -> Double {
        precondition(
            latticeDistance >= 0 && latticeDistance <= 1.0,
            "latticeDistance must be in [0, 1]; got \(latticeDistance)"
        )
        precondition(
            fingerprintHammingDistance <= fingerprintTotalBits,
            "fingerprintHammingDistance \(fingerprintHammingDistance) exceeds total bits \(fingerprintTotalBits)"
        )
        let latPart = alphaLattice * latticeDistance
        guard compatibleSeedScope else { return latPart }
        let fpNormalized = Double(fingerprintHammingDistance)
                            / Double(fingerprintTotalBits)
        return latPart + alphaFingerprint * fpNormalized
    }
}

// MARK: - Properties
//
//   reflexive:         distance(0, 0) = 0.
//   bounded:           with alpha_lattice + alpha_fingerprint = 1
//                      and both inputs in [0, 1] (after fingerprint
//                      normalization), composite in [0, 1].
//   cross-perimeter:   when compatibleSeedScope = false, output
//                      equals alpha_lattice * lattice_distance.
//                      Strictly smaller than the full composite
//                      under positive fingerprint contribution;
//                      the cookbook explicitly intends this
//                      reduction.
//   weight-symmetric:  doubling both alphas doubles the output;
//                      the formula is linear in the alphas.
//
// MARK: - Cookbook references
//   § 8.4   Composite distance definition
//   § 8.3   Lattice distance (one of the two terms)
//   § 8.2   Hamming distance (the other term)
//   § 8.12  Bradley-Terry update for the alphas
//   § 12.2  Pairing handshake (establishes compatibleSeedScope)
