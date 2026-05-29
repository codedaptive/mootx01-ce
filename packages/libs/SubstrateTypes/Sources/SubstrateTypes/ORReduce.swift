// ORReduce.swift
//
// OR-reduction over Fingerprint256 collections per cookbook § 8.5.
//
// OR-reduction is the substrate's universal aggregation primitive.
// It is commutative, associative, and idempotent, which makes it
// ideal for:
//
//   1. Temporal compression (detail → hour → day, cookbook § 8.14)
//   2. Paired-estate shared-context aggregation (case study 1)
//   3. Tier contribution at federation boundaries (cookbook § 12.3)
//   4. Moment-summary fingerprints across noun types (§ 8.7)
//   5. Cross-replica conflict-free merge (CRDT semantics, § 5)
//
// The idempotence property is the privacy mechanism: an
// aggregation of many fingerprints loses attribution (you cannot
// tell which contributor set which bit) while preserving
// structural pattern (bits set in many contributors stay set).

import Foundation

public enum ORReduce {

    /// OR-reduction over a fingerprint sequence. Returns
    /// `Fingerprint256.zero` for empty input (the identity).
    ///
    /// Phase 2 (decision 2026-05-28 §6.2): delegates to the
    /// `Fingerprint256.reduce4` combinator. Bit-identical to the
    /// inline four-block fold it replaces.
    @inlinable
    public static func reduce<S: Sequence>(
        _ fingerprints: S
    ) -> Fingerprint256 where S.Element == Fingerprint256 {
        return Fingerprint256.reduce4(fingerprints, |)
    }

    // Phase 2 deletion: `ORReduce.merge(into:_:)`. Streaming callers
    // now do `accumulator = accumulator.zip4(incoming, |)` (or
    // equivalently `Fingerprint256.reduce4([accumulator, incoming], |)`).
    // No call sites in the repository depended on the in-place form.

    /// OR-reduction restricted to specific blocks. Useful when
    /// aggregating only the topic-block across cohorts, etc.
    /// Blocks not in the set carry over from `defaults`
    /// (typically `Fingerprint256.zero`).
    public static func reduce<S: Sequence>(
        _ fingerprints: S,
        blocks: Set<Int>,
        defaults: Fingerprint256 = .zero
    ) -> Fingerprint256 where S.Element == Fingerprint256 {
        let full = reduce(fingerprints)
        return Fingerprint256(
            block0: blocks.contains(0) ? full.block0 : defaults.block0,
            block1: blocks.contains(1) ? full.block1 : defaults.block1,
            block2: blocks.contains(2) ? full.block2 : defaults.block2,
            block3: blocks.contains(3) ? full.block3 : defaults.block3
        )
    }
}

// MARK: - Algebraic properties (informally verified)
//
// commutative:  OR(a, b) == OR(b, a)
// associative: OR(OR(a, b), c) == OR(a, OR(b, c))
// idempotent:  OR(a, a) == a
//
// These three together make OR-reduction the natural CRDT join
// operator for fingerprint G-Sets. Replicas can merge contribution
// sets in any order, with any duplicate ordering, and converge to
// the same aggregate.

// MARK: - Use sites (cross-reference)
//
//   cookbook § 8.14   compress_to_hourly (12 detail buckets → 1 hour)
//   cookbook § 12.3   generate_contribution (N row fingerprints → 1 tier)
//   cookbook § 11.5   recall_current_posture (recent AmbientSamples → posture)
//   cookbook § 11.15  recall_moment_summary (active rows → moment fingerprint)
//   cookbook § 5.4    sync convergence (commutative join over G-Sets)
