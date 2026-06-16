// MaxSimScorer.swift
//
// Lane E1 — Exact-A (exhaustive) binary MaxSim scorer.
//
// Implements binary ColBERT MaxSim late interaction (retrieval algorithms
// reference §3.B, Exact-A definition) over 256-bit SimHash Engram tokens:
//
//   MaxSim(Q, D) = Σ_{q ∈ Q} ( 256 − min_{d ∈ D} hamming(q, d) )
//
// The computation is exhaustive: for every query token, every document token
// is compared. "Exhaustive" is the correctness guarantee — no document is
// skipped, no candidate pruning is applied. Documents are ranked by MaxSim
// descending, ties broken by itemID ascending (§0.3 universal tie-break).
//
// SCOPE (read before modifying):
//   This file implements Exact-A only. The MIH-accelerated two-stage variant
//   (Exact-B) and MIH-based candidate generation are explicitly out of scope
//   for this lane. Exact-A scores every document in the input set.
//
// I-7 (arch spec §3.1, §3.4): ALL Hamming distances go through EngramLib
// (which routes to SubstrateKernel). There is no XOR/popcount in this file.
// A raw popcount here would bypass the four-way conformance gate and
// introduce potential divergence between the Swift and Rust ports.
//
// Determinism (retrieval algorithms reference §3.C):
//   1. Token similarity is integer: 256 − hamming(q, d). No floats.
//   2. Inner reduction is min over hamming. Min ties are value-irrelevant
//      (we only need the minimal distance, not which token achieved it).
//   3. Query-token iteration order is input order (fixed for trace
//      reproducibility; integer addition is commutative so the score value
//      is independent of query-token order).
//   4. Documents are iterated in sorted ascending itemID order.
//   5. Result ordering: (score DESC, itemID ASC), truncated to k.
//   6. Integer arithmetic only. No floats anywhere on this path.
//
// Thread-safety: MaxSimScorer is a pure value type (struct). Its state is
// an EngramLib.Session used for kernel reuse. The session is Sendable.
// The scorer is Sendable.

import Foundation
import EngramLib
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "VectorKit")

// MARK: - MaxSimHit

/// One document's MaxSim result.
///
/// `score` is the integer MaxSim value: Σ_{q ∈ Q}(256 − min_{d ∈ D} hamming(q,d)).
/// Range: [0, 256 × |Q|].
///
/// Results are ordered (score DESC, itemID ASC) per §0.3 and §3.C rule 5.
/// Identical scores are broken by itemID ascending — the smaller itemID wins.
public struct MaxSimHit: Sendable, Equatable {

    /// The document identifier. Matches the itemID key used in the
    /// `documents` dictionary passed to `MaxSimScorer.score`.
    public let itemID: String

    /// Integer MaxSim score. Larger = more relevant.
    ///
    /// Maximum: 256 × |Q| (all query tokens at Hamming distance 0 from a
    /// document token). Minimum: 0 (all query tokens at Hamming distance 256
    /// — bit-inverse — from every document token).
    public let score: Int

    /// Designated initialiser.
    public init(itemID: String, score: Int) {
        self.itemID = itemID
        self.score = score
    }
}

// MARK: - MaxSimScorer

/// Exact-A binary ColBERT MaxSim scorer.
///
/// Computes MaxSim(Q, D) = Σ_{q ∈ Q}(256 − min_{d ∈ D} hamming(q, d))
/// exhaustively over every document supplied in the input set. Every
/// document is scored; no candidate pruning is applied.
///
/// This scorer is the conformance reference for Lane E1. Any accelerated
/// variant (MIH-pruned Stage-1, Exact-B bound pruning) must produce
/// results identical to this scorer — it is the oracle.
///
/// Example:
/// ```swift
/// let scorer = MaxSimScorer()
/// let results = scorer.score(
///     queryTokens: [tokenA, tokenB],
///     documents: ["doc1": [tok1, tok2], "doc2": [tok3]],
///     k: 10
/// )
/// // results[0] is the highest-MaxSim document.
/// ```
public struct MaxSimScorer: Sendable {

    // MARK: - State

    /// Kernel session reused across all distance calls within a score() call.
    ///
    /// The session holds a single kernel instance; resolving it once per
    /// scorer amortizes the kernel-selection cost across the
    /// O(|Q| × Σ|D_i|) inner-loop Hamming calls. The session is
    /// Sendable and safe to share across tasks.
    private let session: EngramLib.Session

    // MARK: - Init

    /// Designated initialiser. Creates a scorer backed by the platform-optimal
    /// SubstrateKernel (NEON on Apple silicon, scalar elsewhere). The kernel is
    /// selected once here and reused for every distance call in score().
    public init() {
        self.session = EngramLib.session()
    }

    // MARK: - Scoring

    /// Score every document against the query and return the top-k by MaxSim.
    ///
    /// Algorithm (Exact-A, retrieval algorithms reference §3.B):
    /// ```
    /// for each document D, iterated in ascending itemID order:
    ///     score = 0
    ///     for each query token q ∈ Q (input order):
    ///         minDist = min over d ∈ D of hamming(q, d)
    ///         score  += 256 − minDist
    /// sort (score DESC, itemID ASC), return first k.
    /// ```
    ///
    /// All Hamming calls go through `EngramLib.Session.distances` → SubstrateKernel.
    /// There is no XOR or popcount in this method (I-7 absolute).
    ///
    /// Edge cases:
    ///   - `queryTokens` empty: every document scores 0; ordering is itemID ASC.
    ///   - Document token array empty: every query token contributes 0 (no
    ///     candidate for the inner min; we define min-over-empty-set = 256, so
    ///     256 − 256 = 0). Documents with no tokens score 0.
    ///   - `k ≤ 0`: returns empty array.
    ///   - `documents` empty: returns empty array.
    ///
    /// - Parameters:
    ///   - queryTokens: Ordered array of Engram token fingerprints for the query.
    ///   - documents: Mapping from itemID to the document's Engram token array.
    ///   - k: Maximum results to return. Pass `Int.max` for the full ranked list.
    /// - Returns: Up to `k` MaxSimHit values sorted (score DESC, itemID ASC).
    public func score(
        queryTokens: [Engram],
        documents: [String: [Engram]],
        k: Int
    ) -> [MaxSimHit] {
        guard k > 0, !documents.isEmpty else { return [] }

        // Enumerate documents in ascending itemID order (§3.C rule 4).
        // Dictionary iteration order is undefined; sorting keys here ensures
        // deterministic enumeration regardless of hash-map internals.
        let sortedItemIDs = documents.keys.sorted()

        var results: [MaxSimHit] = []
        results.reserveCapacity(documents.count)

        for itemID in sortedItemIDs {
            // documents[itemID] is always non-nil because we iterate keys.
            let docTokens = documents[itemID]!
            let docScore = computeMaxSim(
                queryTokens: queryTokens,
                docTokens: docTokens
            )
            results.append(MaxSimHit(itemID: itemID, score: docScore))
        }

        // Sort: score DESC primary, itemID ASC tiebreak (§0.3 universal rule).
        // This sort is over the full scored set; truncation to k happens after
        // the total-order sort (§0.4 rule 4 — never truncate before sorting).
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.itemID < rhs.itemID
        }

        if results.count > k {
            results = Array(results.prefix(k))
        }

        log.debug("MaxSimScorer: scored \(results.count) docs, k=\(k)")
        return results
    }

    // MARK: - Private

    /// Compute MaxSim(Q, D) for a single document.
    ///
    /// MaxSim(Q, D) = Σ_{q ∈ Q} (256 − min_{d ∈ D} hamming(q, d))
    ///
    /// All Hamming distances are delegated to `EngramLib.Session.distances`,
    /// which routes through SubstrateKernel — I-7 absolute. No XOR or popcount
    /// appears here.
    ///
    /// - Parameters:
    ///   - queryTokens: Query token fingerprints (may be empty → returns 0).
    ///   - docTokens: Document token fingerprints (may be empty → returns 0).
    /// - Returns: Integer MaxSim score for this document.
    private func computeMaxSim(
        queryTokens: [Engram],
        docTokens: [Engram]
    ) -> Int {
        guard !queryTokens.isEmpty, !docTokens.isEmpty else { return 0 }

        var totalScore = 0

        for queryToken in queryTokens {
            // Compute Hamming distances from this query token to all document
            // tokens in one batch call. The session's distances() method is the
            // I-7-compliant entry point: it dispatches to SubstrateKernel.
            //
            // distances returns one Int per docToken, same indexing. We only
            // need the minimum — we do not care which document token achieved it
            // (§3.C rule 2: min-ties are value-irrelevant).
            let distances = session.distances(probe: queryToken, candidates: docTokens)

            // distances is non-empty because docTokens is non-empty (checked above).
            // min() on a non-empty Swift collection is always non-nil.
            let minDist = distances.min()!

            // Integer similarity contribution (§3.C rule 1, §0.2 integer-only).
            // 256 − minDist is in [0, 256]; summing over |Q| tokens stays within Int.
            totalScore += 256 - minDist
        }

        return totalScore
    }
}
