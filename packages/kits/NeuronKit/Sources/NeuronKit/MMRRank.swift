// MMRRank.swift
//
// Standalone Maximal Marginal Relevance (MMR) diversity rerank, per
// NEURONKIT_SPEC § 4.1 step 4. MMR re-orders a recall result set to
// balance relevance against redundancy: each selection step picks the
// candidate that maximises
//
//     λ × relevance(candidate, query) − (1−λ) × maxSim(candidate, selected)
//
// where `selected` is the set already chosen. This is the canonical
// Engram-distance implementation the spec prescribes. It is distinct
// from the inline shingle-Jaccard MMR inside `HybridRecallEngine`,
// which is a vector-free proxy bounded by invariant B-1 (the wrapper
// has no Engram access). Reconciling the two is a separate mission
// (NK-MMR-02); this file does not touch the inline path.
//
// Relevance and similarity are derived from EngramLib's Hamming
// `distance(_:_:)` (range 0...256) normalised into [0, 1]:
//
//     score = 1 − distance / 256.0
//
// so identical engrams score 1.0 and bit-inverses score 0.0. The
// engine is pure data-in / data-out — no Drawer, no estate, no clocks,
// no randomness — so the Swift conformance tests and the future Rust
// port exercise identical math against shared vectors, matching the
// `HybridRecallEngine` pattern already in the kit.

import EngramLib

/// MMR diversity rerank per NEURONKIT_SPEC § 4.1 step 4.
///
/// Re-orders `candidates` to balance relevance to `query` against
/// redundancy among the chosen rows, returning the top `k` in MMR
/// selection order.
///
/// `fingerprint` converts each candidate Drawer to its `Engram`. The
/// caller owns the estate and supplies the derivation (typically
/// `EstateFingerprintFamilies.fingerprint(of:)`), keeping this
/// function free of estate context per invariant B-1 — `mmrRank`
/// performs no substrate access of its own.
///
/// - Parameters:
///   - candidates: the rows to rerank, in their incoming order. The
///     incoming order is the tie-break basis (see below).
///   - query: the engram the relevance term is measured against.
///   - lambda: the MMR trade-off in [0, 1]. `1.0` is pure relevance
///     (closest-to-query first); `0.0` is pure diversity (each pick
///     maximises distance from what is already selected).
///   - k: the maximum number of rows to return. `k <= 0` returns
///     empty; `k >= candidates.count` returns all candidates reranked.
///   - fingerprint: per-candidate engram derivation owned by the caller.
/// - Returns: up to `k` candidates in MMR selection order. Ties are
///   broken by ascending input index, so the result is deterministic
///   and reproducible across the Swift and Rust ports.
public func mmrRank(
    candidates: [Drawer],
    query: Engram,
    lambda: Float,
    k: Int,
    fingerprint: (Drawer) -> Engram
) -> [Drawer] {
    guard k > 0, !candidates.isEmpty else { return [] }

    // Project candidates to engrams once, preserving index alignment,
    // so the engine works on plain fingerprints with no Drawer access.
    let fingerprints = candidates.map(fingerprint)
    let order = MMREngine.select(
        fingerprints: fingerprints,
        query: query,
        lambda: lambda,
        k: k
    )
    return order.map { candidates[$0] }
}

/// Pure MMR selection over engram fingerprints. Internal so the Swift
/// conformance tests and the Rust port run identical math against the
/// same vectors; the public `mmrRank` is the Drawer-facing wrapper.
///
/// No Drawer, no estate, no clocks, no randomness — every output is a
/// deterministic function of the inputs.
internal enum MMREngine {

    /// Maximum Hamming distance between two 256-bit engrams. EngramLib
    /// guarantees `distance(_:_:)` returns 0...256, so dividing by this
    /// maps any distance into [0, 1]. Named rather than inlined so the
    /// normalisation basis is explicit and the Rust port uses the same
    /// constant.
    private static let maxEngramDistance: Float = 256.0

    /// Hamming distance normalised into a [0, 1] closeness score:
    /// `1 − distance / maxEngramDistance`. Identical engrams score 1.0
    /// and complete bit-inverses score 0.0. The same form serves both
    /// the relevance term (candidate vs query) and the similarity term
    /// (candidate vs selected), as the spec's formula requires.
    private static func closeness(_ a: Engram, _ b: Engram) -> Float {
        return 1.0 - Float(EngramLib.distance(a, b)) / maxEngramDistance
    }

    /// Greedy MMR selection. Returns selected indices into
    /// `fingerprints`, in MMR order, truncated to `k`.
    ///
    /// Complexity is O(k · n): each of the up-to-`k` selection rounds
    /// scans the remaining candidates, and the per-candidate similarity
    /// to the selected set is tracked incrementally (only the
    /// just-selected row's contribution is folded in each round) rather
    /// than recomputed against all of `selected`.
    ///
    /// Tie-break: candidates are scanned in ascending input-index order
    /// and a strictly-greater (`>`) comparison keeps the earliest
    /// candidate when scores are equal. Equal scores therefore resolve
    /// to ascending input index, which the Rust port must reproduce.
    static func select(
        fingerprints: [Engram],
        query: Engram,
        lambda: Float,
        k: Int
    ) -> [Int] {
        guard k > 0, !fingerprints.isEmpty else { return [] }

        let n = fingerprints.count
        let limit = min(k, n)

        // Relevance term per candidate — fixed across rounds.
        let relevance = fingerprints.map { closeness($0, query) }

        // Running maximum similarity of each candidate to the selected
        // set. Starts at 0 (nothing selected). After each pick we fold
        // in the new selection's similarity, so `maxSimToSelected[i]`
        // always equals max_j Sim(i, selected_j). This keeps the loop
        // O(k · n) instead of O(k² · n).
        var maxSimToSelected = [Float](repeating: 0, count: n)
        var isSelected = [Bool](repeating: false, count: n)

        var selected: [Int] = []
        selected.reserveCapacity(limit)

        while selected.count < limit {
            var bestIdx = -1
            var bestScore: Float = -.infinity
            for i in 0..<n where !isSelected[i] {
                // MMR(i) = λ·relevance(i) − (1−λ)·maxSim(i, selected).
                let score = lambda * relevance[i]
                    - (1 - lambda) * maxSimToSelected[i]
                // Strict `>` plus ascending scan = input-index tie-break.
                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }

            // `bestIdx` is always valid: the loop runs only while at
            // least one unselected candidate remains, and any finite
            // score exceeds the -infinity seed.
            isSelected[bestIdx] = true
            selected.append(bestIdx)

            // Fold the new pick into every remaining candidate's running
            // max similarity, ready for the next round.
            let pick = fingerprints[bestIdx]
            for i in 0..<n where !isSelected[i] {
                let sim = closeness(fingerprints[i], pick)
                if sim > maxSimToSelected[i] { maxSimToSelected[i] = sim }
            }
        }

        return selected
    }
}
