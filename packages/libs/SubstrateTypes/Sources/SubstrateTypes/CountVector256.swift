// CountVector256.swift
//
// Count-vector over the 256-bit fingerprint space, the stored
// object for the bundle algebra per
// DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20.md and the scope
// in docs/analysis/bundle_algebra/SCOPE_MAJORITY_VOTE_TREE_FOLD_2026-05-20.md.
//
// For a set of member fingerprints, the count-vector holds, for each
// of the 256 bit positions, how many members have that bit set
// (`counts[j]` = c_j) together with the member count (`n`). The
// normalized profile p_j = c_j / n is the probability a random member
// lights bit j, equivalently the parameter of bit j's Bernoulli.
//
// Why this and not a majority-vote engram. The count-vector composes
// losslessly up a node tree: counts add and n adds, and a parent's
// count-vector equals the direct accumulation of every leaf under it,
// exactly, regardless of fold order. Majority-vote does not compose;
// the majority of children's majorities disagrees with the true
// majority of the pooled members. So the stored object is the count-
// vector, and the majority-vote engram that Hamming recall consumes is
// a read-time view obtained by thresholding 2*c_j > n. The honest
// statistic yields the engram for free; the engram cannot yield the
// statistic. This is the mergeability property that separates linear
// sketches from thresholded summaries, and it makes the bundle a
// conflict-free replicated data type by construction.
//
// The existing OR-reduce is the degenerate case of this same fold,
// where the per-bit accumulator saturates at one instead of counting.

import Foundation

/// Count-vector `(c, n)` over the 256-bit fingerprint space.
///
/// `counts` always has exactly 256 entries; `counts[j]` is the number
/// of accumulated members whose bit `j` is set. `n` is the member
/// count. The all-zero value (no members) is the fold identity.
///
/// Counts are `UInt32`, bounding a single vector to about 4.3 billion
/// members before a count could saturate, well above any realistic
/// node subtree size. The merge is plain integer addition; callers
/// composing pathologically large trees should note the bound.
public struct CountVector256: Sendable, Equatable, Codable {

    /// Per-bit set counts, exactly 256 entries. `counts[j]` = c_j.
    public private(set) var counts: [UInt32]

    /// Member count. Equals the number of `accumulate` calls plus the
    /// `n` of every merged-in vector.
    public private(set) var n: UInt32

    /// The empty count-vector: all counts zero, `n` zero. This is the
    /// identity element of the fold and merge.
    public static let zero = CountVector256()

    /// Construct the empty count-vector.
    public init() {
        self.counts = [UInt32](repeating: 0, count: 256)
        self.n = 0
    }

    /// Construct from explicit counts and member count. `counts` must
    /// have exactly 256 entries. Used for decoding a stored vector and
    /// for tests; normal construction is by `accumulate` or `merge`.
    public init(counts: [UInt32], n: UInt32) {
        precondition(counts.count == 256,
                     "CountVector256 requires exactly 256 counts")
        self.counts = counts
        self.n = n
    }

    // MARK: - Accumulation

    /// Fold one fingerprint into the vector: for each set bit, raise
    /// that bit's count by one, and raise `n` by one. This is the leaf
    /// step of the fold.
    public mutating func accumulate(_ fingerprint: Fingerprint256) {
        for blockIndex in 0..<4 {
            var word = fingerprint.block(at: blockIndex)
            let base = blockIndex * 64
            while word != 0 {
                let bit = word.trailingZeroBitCount
                counts[base + bit] &+= 1
                word &= word &- 1            // clear lowest set bit
            }
        }
        n &+= 1
    }

    // MARK: - Merge (the tree-fold step)

    /// Merge another count-vector into this one: add counts elementwise
    /// and add `n`. Commutative and associative, so folding a node's
    /// children in any order yields the same result, and the result
    /// equals the direct accumulation of every leaf under the node.
    public mutating func merge(_ other: CountVector256) {
        for j in 0..<256 {
            counts[j] &+= other.counts[j]
        }
        n &+= other.n
    }

    /// Functional merge. `a + b` is the count-vector whose counts are
    /// the elementwise sum and whose `n` is the sum of member counts.
    public static func + (lhs: CountVector256, rhs: CountVector256) -> CountVector256 {
        var result = lhs
        result.merge(rhs)
        return result
    }

    // MARK: - Reads

    /// The majority-vote engram. Bit `j` is set if and only if a
    /// strict majority of members have it set, `2 * c_j > n`. The
    /// strict inequality matches the proof's indicator `1[c_j/n > 0.5]`:
    /// an exact tie at half does not set the bit. This tie convention
    /// is part of the contract and is identical across every kernel
    /// backend and across the Swift and Rust ports.
    ///
    /// An empty vector (`n == 0`) yields the zero fingerprint, since no
    /// bit can clear `2 * 0 > 0`.
    public func majorityVote() -> Fingerprint256 {
        let threshold = UInt64(n)
        var fp = Fingerprint256.zero
        for j in 0..<256 where UInt64(counts[j]) &* 2 > threshold {
            fp = fp.with(bit: j, set: true)
        }
        return fp
    }

    /// The normalized profile, `p_j = c_j / n`, the probability a
    /// random member lights bit `j`. Returns 256 values in `[0, 1]`.
    /// An empty vector (`n == 0`) yields all zeros: with no members,
    /// no bit is ever lit. This read is not stored; it is recomputed
    /// when the Bernoulli or KL-drift views need it.
    public func profile() -> [Float] {
        guard n > 0 else { return [Float](repeating: 0, count: 256) }
        let denom = Float(n)
        return counts.map { Float($0) / denom }
    }
}

// MARK: - Reference fold

extension CountVector256 {
    /// Accumulate a slice of fingerprints into a single count-vector.
    /// This is the reference fold the kernel layer's `countFold256`
    /// dispatches to; performance backends may compute the same result
    /// by a vectorized vertical counter, gated against this reference.
    public static func fold(_ fingerprints: [Fingerprint256]) -> CountVector256 {
        var cv = CountVector256()
        for fp in fingerprints {
            cv.accumulate(fp)
        }
        return cv
    }
}
