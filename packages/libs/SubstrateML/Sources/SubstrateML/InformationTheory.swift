// InformationTheory.swift
//
// Information-theoretic primitives per cookbook § 8.11.
//
// Entropy, mutual information, KL divergence, and cross-entropy
// over discrete probability distributions. Used by the substrate
// to quantify uncertainty in bitmap distributions, dependence
// between bitmap fields (via mutual information on O matrix
// slices), and the divergence of recent fingerprint windows
// from the long-term baseline.
//
//   H(p)         = -Σ p_i log2 p_i
//   I(X;Y)       = Σ_{x,y} p(x,y) log2 (p(x,y) / (p(x) p(y)))
//   KL(p ‖ q)    = Σ p_i log2 (p_i / q_i)
//   H(p, q)      = -Σ p_i log2 q_i
//
// Convention: log base 2 throughout, so units are bits. All
// inputs MUST be valid probability distributions (non-negative,
// summing to 1.0 within float tolerance). The reference does
// NOT validate inputs at runtime; callers are responsible.
//
// Numerical care: terms where p_i or q_i is zero are skipped
// (using the conventional 0·log(0) = 0). Division by zero in
// KL would be infinity; we also skip these terms and document
// the result as a lower bound when this happens.
//
// Used by:
//   § 8.11   Information theory definition (this file)
//   § 8.13   Anomaly detection (KL divergence baseline drift)
//   § 8.9    NMF factor interpretation (factor entropy)
//   § 11.16  recall_similar_moments_by_summary (window divergence)

import Foundation

public enum InformationTheory {

    /// Shannon entropy in bits.
    public static func entropy(_ p: [Float32]) -> Float32 {
        var h: Float32 = 0
        for pi in p where pi > 0 {
            h -= pi * log2(pi)
        }
        return h
    }

    /// Mutual information I(X;Y) in bits over a joint distribution
    /// p(x, y). The joint must be normalized so its cells sum to 1.0.
    public static func mutualInformation(joint: [[Float32]]) -> Float32 {
        guard !joint.isEmpty else { return 0 }
        let m = joint.count
        let n = joint[0].count
        var pX = [Float32](repeating: 0, count: m)
        var pY = [Float32](repeating: 0, count: n)
        for i in 0..<m {
            for j in 0..<n {
                pX[i] += joint[i][j]
                pY[j] += joint[i][j]
            }
        }
        var mi: Float32 = 0
        for i in 0..<m {
            for j in 0..<n {
                let p = joint[i][j]
                if p > 0 && pX[i] > 0 && pY[j] > 0 {
                    mi += p * log2(p / (pX[i] * pY[j]))
                }
            }
        }
        return mi
    }

    /// Kullback-Leibler divergence KL(p ‖ q) in bits. Asymmetric;
    /// undefined when p_i > 0 and q_i = 0 (we return a lower bound
    /// in that case by skipping the offending terms).
    public static func klDivergence(_ p: [Float32], _ q: [Float32]) -> Float32 {
        precondition(p.count == q.count,
                     "p and q must have matching support")
        var kl: Float32 = 0
        for i in 0..<p.count {
            if p[i] > 0 && q[i] > 0 {
                kl += p[i] * log2(p[i] / q[i])
            }
        }
        return kl
    }

    /// Cross entropy H(p, q) in bits.
    public static func crossEntropy(_ p: [Float32], _ q: [Float32]) -> Float32 {
        precondition(p.count == q.count,
                     "p and q must have matching support")
        var ce: Float32 = 0
        for i in 0..<p.count where p[i] > 0 && q[i] > 0 {
            ce -= p[i] * log2(q[i])
        }
        return ce
    }

    /// Symmetric Jensen-Shannon divergence in bits. Bounded in [0, 1].
    public static func jensenShannon(_ p: [Float32], _ q: [Float32]) -> Float32 {
        precondition(p.count == q.count,
                     "p and q must have matching support")
        let m = zip(p, q).map { ($0 + $1) / 2 }
        return 0.5 * klDivergence(p, m) + 0.5 * klDivergence(q, m)
    }

    /// Normalized mutual information NMI = 2·I(X;Y) / (H(X) + H(Y))
    /// in [0, 1]. Useful for ranking field-field dependence in O.
    ///
    /// Returns 0 (the same sentinel `mutualInformation` returns) when
    /// `joint` is empty or ragged (rows of unequal length). This matches
    /// the totality contract of `mutualInformation`.
    public static func normalizedMutualInformation(joint: [[Float32]]) -> Float32 {
        guard !joint.isEmpty else { return 0 }
        let n = joint[0].count
        // Ragged matrix: unequal row lengths corrupt the pY accumulation,
        // producing wrong marginals and wrong NMI. Return the sentinel.
        guard joint.allSatisfy({ $0.count == n }) else { return 0 }
        let mi = mutualInformation(joint: joint)
        let m = joint.count
        var pX = [Float32](repeating: 0, count: m)
        var pY = [Float32](repeating: 0, count: n)
        for i in 0..<m {
            for j in 0..<n {
                pX[i] += joint[i][j]
                pY[j] += joint[i][j]
            }
        }
        let denom = entropy(pX) + entropy(pY)
        return denom > 0 ? 2 * mi / denom : 0
    }
}
