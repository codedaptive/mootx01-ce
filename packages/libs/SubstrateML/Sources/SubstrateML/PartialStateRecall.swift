// PartialStateRecall.swift
//
// Partial-state recall per cookbook § 8.8.
//
// Standard nearest-neighbor asks "find me rows similar to this
// anchor on all blocks." Partial-state recall asks "find me rows
// similar on this subset of blocks AND different on this other
// subset." It is the substrate's primitive for queries like
// "rows about the same topic but in a different behavioral state"
// (match on block 1 / lattice, differ on block 2 / lineage and
// recency) or "moments observationally similar but from a
// different sensitivity class" (match on blocks 0-2, differ on
// block 3 / channel and source).
//
// Score formula (cookbook § 8.8):
//
//   match_total_bits  = 64 * |match_blocks|
//   differ_total_bits = 64 * |differ_blocks|
//   match_d           = hamming(row.fp, anchor, blocks=match_blocks)
//   differ_d          = hamming(row.fp, anchor, blocks=differ_blocks)
//   match_score       = 1 - (match_d  / match_total_bits)
//   differ_score      = differ_d / differ_total_bits
//   partial_score     = match_score * differ_score          ∈ [0, 1]
//
// High score ⇒ near on match_blocks AND far on differ_blocks.
// Zero score in either factor zeros the product, so a row that
// matches perfectly on match_blocks but is identical on
// differ_blocks scores zero, and a row that differs maximally
// on differ_blocks but is unrelated on match_blocks also scores
// zero. Only rows satisfying both constraints score high.
//
// Used by CognitionKit § 11.10 (recall_partial_match), which
// scores all rows under the predicate-based candidate filter and
// returns the top-K by descending score.
//
// Input validation convention (MX-Tidy, 2026-06-05):
//
//   Block IDs must be in the domain {0, 1, 2, 3}. An out-of-domain
//   block ID is a programmer error: `hammingBlocks` ignores the
//   unknown block but the denominator still counts it, producing
//   silently wrong scores. Both `score` and `topK` assert via
//   `precondition` — consistent with `HammingNN.topK`'s k > 0
//   precondition and BradleyTerry's parameter assertions.
//
//   `k` in `topK` must be non-negative. `prefix(-n)` in Swift
//   crashes; the explicit precondition makes the contract visible
//   and matches HammingNN.topK's style.
//
// Cookbook references:
//   § 8.8   Partial-state recall definition
//   § 8.2   Hamming distance with block subset
//   § 3.1   Four-block fingerprint structure
//   § 11.10 recall_partial_match primitive

import Foundation
import SubstrateTypes

public enum PartialStateRecall {

    /// Compute the partial-match score for a single row against
    /// an anchor fingerprint.
    ///
    /// `matchBlocks` and `differBlocks` are subsets of {0, 1, 2, 3}.
    /// They MAY overlap, but a block in both contributes
    /// contradictorily and is typically disallowed by callers. The
    /// reference does not enforce disjointness; the math is well-
    /// defined either way.
    ///
    /// Returns 0.0 if either block subset is empty (degenerate
    /// case: no "match" or no "differ" constraint imposed).
    ///
    /// Precondition: all block IDs must be in {0, 1, 2, 3}. An
    /// out-of-domain ID corrupts the denominator while not
    /// contributing to the Hamming distance, yielding a wrong score.
    public static func score(
        rowFingerprint: Fingerprint256,
        anchor: Fingerprint256,
        matchBlocks: Set<Int>,
        differBlocks: Set<Int>
    ) -> Double {
        precondition(matchBlocks.allSatisfy { (0...3).contains($0) },
                     "matchBlocks IDs must be in domain {0, 1, 2, 3}")
        precondition(differBlocks.allSatisfy { (0...3).contains($0) },
                     "differBlocks IDs must be in domain {0, 1, 2, 3}")
        if matchBlocks.isEmpty || differBlocks.isEmpty { return 0.0 }
        let matchTotalBits  = 64 * matchBlocks.count
        let differTotalBits = 64 * differBlocks.count
        let matchD  = hammingBlocks(rowFingerprint, anchor, blocks: matchBlocks)
        let differD = hammingBlocks(rowFingerprint, anchor, blocks: differBlocks)
        let matchScore  = 1.0 - Double(matchD)  / Double(matchTotalBits)
        let differScore = Double(differD) / Double(differTotalBits)
        return matchScore * differScore
    }

    /// Top-K rows by descending partial-match score.
    ///
    /// Production code consults the bit-slice tensor and computes
    /// partial scores in batched SIMD; this reference is a
    /// straightforward scan over `rows`.
    ///
    /// Precondition: `k >= 0`. Negative k is a programmer error;
    /// `prefix` would crash — the precondition makes the contract
    /// explicit, matching `HammingNN.topK`'s `k > 0` style.
    public static func topK(
        anchor: Fingerprint256,
        rows: [(rowId: UUID, fingerprint: Fingerprint256)],
        matchBlocks: Set<Int>,
        differBlocks: Set<Int>,
        k: Int
    ) -> [(rowId: UUID, score: Double)] {
        precondition(k >= 0, "k must be non-negative")
        var scored: [(UUID, Double)] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            let s = score(rowFingerprint: row.fingerprint, anchor: anchor,
                           matchBlocks: matchBlocks, differBlocks: differBlocks)
            scored.append((row.rowId, s))
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(k))
    }

    // MARK: - Helper: Hamming distance over a block subset
    //
    // Mirrors glref-swift-Hamming.swift's block-subset overload.

    @inlinable
    public static func hammingBlocks(
        _ a: Fingerprint256,
        _ b: Fingerprint256,
        blocks: Set<Int>
    ) -> Int {
        var d = 0
        if blocks.contains(0) { d += (a.block0 ^ b.block0).nonzeroBitCount }
        if blocks.contains(1) { d += (a.block1 ^ b.block1).nonzeroBitCount }
        if blocks.contains(2) { d += (a.block2 ^ b.block2).nonzeroBitCount }
        if blocks.contains(3) { d += (a.block3 ^ b.block3).nonzeroBitCount }
        return d
    }
}

// MARK: - Properties
//
//   range:        score ∈ [0, 1]. matchScore ∈ [0, 1]; differScore ∈
//                 [0, 1]; product ∈ [0, 1].
//   identical:    score(anchor, anchor, match, differ) = 1 * 0 = 0
//                 for non-empty differ_blocks. The anchor itself
//                 fails the "differ" constraint trivially.
//   inverse:      score(complement, anchor, match, differ) =
//                 0 * 1 = 0. A fingerprint with every bit flipped
//                 relative to the anchor fails the "match" constraint.
//   product-zero: if either block-subset count is zero, the score
//                 is zero (degenerate case handled explicitly).
//
// MARK: - Cookbook references
//   § 8.8   Partial-state recall definition (the spec)
//   § 8.2   Hamming distance over block subsets
//   § 3.1   Four-block fingerprint structure
//   § 11.10 recall_partial_match primitive (the consumer)
