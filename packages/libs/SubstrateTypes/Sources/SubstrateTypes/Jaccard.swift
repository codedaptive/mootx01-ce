// Jaccard.swift
//
// Jaccard similarity over 256-bit fingerprints (W2.5 Track M1 activation,
// DECISION_DENSE_LANE_ENRICHMENT program / dark-computation audit
// 2026-08-20: the metric was designed into DenseMetric and rejected at
// runtime — this is its kernel-composition unlock).
//
// Jaccard(a, b) = popcount(a AND b) / popcount(a OR b) — both operands
// INTEGER popcounts over the same conformance-gated primitives Hamming
// uses (`zip4` + `popcount`; scalar is the oracle, SubstrateLib kernel
// dispatch note applies unchanged). The final division is the only
// floating-point step, and its integer operands make it bit-identical
// across ports (same IEEE-754 double division of exact small integers).
//
// Empty-union convention: two all-zero fingerprints share no set bits and
// no possible bits — similarity is defined as 0.0 (NOT 1.0): an all-zero
// fingerprint carries no evidence, and "no evidence" must never read as a
// perfect match in a retrieval lane. Mirrors the Rust twin exactly.

public enum Jaccard {

    /// Jaccard similarity in [0, 1]. 1.0 = identical non-empty bit sets;
    /// 0.0 = disjoint sets OR both empty (see empty-union convention).
    @inlinable
    public static func similarity(_ a: Fingerprint256, _ b: Fingerprint256) -> Double {
        let unionCount = a.zip4(b, |).popcount()
        guard unionCount > 0 else { return 0.0 }
        let intersectionCount = a.zip4(b, &).popcount()
        return Double(intersectionCount) / Double(unionCount)
    }

    /// Jaccard distance in [0, 1]: `1 - similarity`.
    @inlinable
    public static func distance(_ a: Fingerprint256, _ b: Fingerprint256) -> Double {
        1.0 - similarity(a, b)
    }
}
