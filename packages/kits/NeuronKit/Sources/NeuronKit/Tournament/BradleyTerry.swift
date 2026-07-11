// BradleyTerry.swift
//
// Deterministic Bradley-Terry batch maximum-likelihood ranker
// (mission NK-BT-01, NEURONKIT_SPEC § 4.4 Tournament scoring).
//
// Given a complete set of pairwise win/loss outcomes between named
// competitors, estimate each competitor's latent strength and rank
// them. This is the BATCH MLE form. It is distinct from the cookbook
// § 8.12 `bradley_terry_update` online-gradient weight-learner: that
// tunes a feature-weight vector one comparison at a time; this fits a
// per-competitor strength from a full tally. They share the BT sigmoid
// model and nothing else. No symbol here collides with § 8.12.
//
// This is a NeuronKit reasoning function: it reads its inputs,
// computes, and returns. It calls no estate verb, touches no
// substrate, executes no SQL (behavioural contract B-1/B-3).
//
// DETERMINISM (hard requirement, CLAUDE.md). Same inputs always
// produce the same `[BradleyTerryScore]`, bit-for-bit, including CI
// bounds. The BT math has no wall-clock read, no randomness, no
// unseeded iteration. The telemetry section reads `Date()` for metric
// timestamps only — those reads do not affect the returned scores.
// The competitor set is materialised as a LEXICOGRAPHICALLY SORTED
// array (`ids`); every subsequent loop iterates that array by integer
// index, never a `Set` or `Dictionary` in hash order. Tally
// accumulation is commutative addition, so the result is also
// invariant to the order of the `outcomes` array.

import Foundation
import IntellectusLib

/// Structured errors raised by the Bradley-Terry fitter. Per the
/// project convention, each module owns a typed `MOOTx01Error` enum
/// rather than returning optionals plus logging. These two cases are
/// NeuronKit's.
public enum MOOTx01Error: Error, Sendable, Equatable {

    /// A `PairwiseOutcome` had `winner == loser`. A competitor cannot
    /// beat itself; this is a programmer error in tally construction,
    /// surfaced rather than silently dropped. Carries the offending ID.
    case selfPairing(competitor: String)

    /// The directed win graph is not strongly connected, so the
    /// maximum-likelihood estimate is not finite.
    ///
    /// Why strong connectivity and not merely "everyone played
    /// someone": the BT MLE is finite and unique if and only if, in the
    /// directed graph with an edge `i → j` whenever `i` beat `j` at
    /// least once, every competitor is reachable from every other
    /// (Ford 1957; Hunter 2004 § 3). A competitor that never wins has
    /// MLE strength −∞; one that never loses has +∞. Since the mission
    /// requires every returned score to carry a FINITE 95% confidence
    /// interval, non-finite estimates cannot be represented and are
    /// rejected here. This condition strictly subsumes the simpler
    /// "a competitor or group never compared against the rest" case
    /// (an undirected-disconnected graph is never strongly connected),
    /// so that case throws too.
    case disconnectedComparisonGraph

    /// More competitors than the fitter admits. Bradley-Terry allocates
    /// dense O(n²) matrices and runs up to `bradleyTerryMaxIterations`
    /// O(n²) sweeps, so an unbounded competitor count (e.g. one preference
    /// room per attacker-created room) is a CPU/memory-exhaustion vector.
    /// Carries the offending count. Mirrors Rust
    /// `TournamentError::TooManyCompetitors`.
    case tooManyCompetitors(count: Int)
}

/// Convergence tolerance for the MM fixed-point iteration: the fit
/// stops when the maximum RELATIVE change of any linear strength across
/// one full sweep falls below this. 1e-9 is well inside Double
/// precision for the normalised strengths (which sit near 1.0) and is
/// tight enough that the returned CI bounds are stable to many decimal
/// places, satisfying the bit-for-bit determinism test.
private let bradleyTerryEpsilon = 1e-9

/// Hard cap on MM sweeps. The MM update increases the likelihood
/// monotonically and converges geometrically on a strongly-connected
/// graph, so well-posed inputs converge in far fewer than this; the cap
/// only bounds pathologically ill-conditioned (but still connected)
/// graphs. Reaching the cap is not an error — the last iterate is
/// returned — but in practice the determinism/convergence tests show
/// convergence long before it.
private let bradleyTerryMaxIterations = 10_000

/// The standard-normal 0.975 quantile, scaling a standard error
/// to a two-sided 95% confidence interval (`strength ± z · SE`). The
/// mission pins this at 1.96, the conventional rounded value.
private let bradleyTerryZ95 = 1.96

/// Fits the Bradley-Terry model to a set of pairwise outcomes and
/// returns one score per competitor, ranked strongest first.
///
/// - Parameter outcomes: win/loss records between named competitors.
///   `count` aggregates repeated identical outcomes;
///   `PairwiseOutcome(winner: a, loser: b, count: 5)` is exactly five
///   single-count records. A non-positive `count` contributes no tally
///   weight but its competitors are still added to the graph — a
///   zero-count-only record can affect the connectivity gate.
/// - Returns: scores sorted by descending `strength`, ties broken by
///   ascending `competitorID` (a deterministic, stable order). Empty
///   input returns `[]`.
/// - Throws: `MOOTx01Error.selfPairing` if any record has
///   `winner == loser`; `MOOTx01Error.disconnectedComparisonGraph` if
///   the win graph is not strongly connected (MLE not finite).
public func bradleyTerry(outcomes: [PairwiseOutcome]) throws -> [BradleyTerryScore] {
    // This body is long by design: it is the eight-step BT MLE
    // algorithm kept in one place so the data flow (tally → connectivity
    // gate → MM iteration → strength + CI → rank) reads top to bottom
    // without indirection, and each step carries the mathematical
    // explanation a future agent needs. The length is comments and
    // straight-line numeric code, not branching complexity.

    // 1. Validate. A self-pairing is rejected regardless of `count` —
    //    it is a malformed record, not a quantity-zero one.
    for outcome in outcomes where outcome.winner == outcome.loser {
        throw MOOTx01Error.selfPairing(competitor: outcome.winner)
    }
    // Empty input is a well-defined "no competitors" answer, not an
    // error.
    if outcomes.isEmpty { return [] }

    // 2. Build the competitor set as the sorted-unique union of every
    //    winner and loser ID. The lexicographic sort is the ONLY place
    //    iteration order is fixed; the `Set` is never iterated in hash
    //    order. `ids` indexes every array below.
    var idSet = Set<String>()
    for outcome in outcomes {
        idSet.insert(outcome.winner)
        idSet.insert(outcome.loser)
    }
    let ids = idSet.sorted()
    let n = ids.count
    // Index lookup is read-only; the dictionary is never iterated.
    var index = [String: Int]()
    for (slot, id) in ids.enumerated() { index[id] = slot }

    // 3. Tally wins per competitor (`wins[i]` = w_i) and total pairwise
    //    comparison counts (`pairCount[i][j]` = n_ij, symmetric, summed
    //    over both directions). `winEdge[i][j]` records whether i beat j
    //    at least once, for the connectivity gate. Addition is
    //    commutative, so these tallies — and therefore the whole result
    //    — do not depend on the order of `outcomes`.
    var wins = [Double](repeating: 0, count: n)
    var pairCount = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    var winEdge = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
    for outcome in outcomes {
        // Non-positive counts contribute nothing (see PairwiseOutcome).
        guard outcome.count > 0 else { continue }
        let c = Double(outcome.count)
        let i = index[outcome.winner]!
        let j = index[outcome.loser]!
        wins[i] += c
        pairCount[i][j] += c
        pairCount[j][i] += c
        winEdge[i][j] = true
    }

    // 4. Finiteness gate: the MLE exists and is finite iff the directed
    //    win graph is strongly connected (see
    //    MOOTx01Error.disconnectedComparisonGraph). Reject otherwise so
    //    every returned strength and CI is finite.
    if !isStronglyConnected(winEdge: winEdge, count: n) {
        throw MOOTx01Error.disconnectedComparisonGraph
    }

    // 5. MM (minorization-maximization) fixed-point iteration on the
    //    LINEAR strengths p_i > 0 (Hunter 2004). Update:
    //        p_i  ←  w_i / Σ_{j≠i} n_ij / (p_i + p_j)
    //    Each sweep is renormalised to geometric mean 1 (equivalently,
    //    log strengths sum to zero) — this fixes the additive gauge
    //    freedom of the model, keeps the iterates O(1) for numerical
    //    stability, and makes results comparable across calls. Strong
    //    connectivity guarantees w_i > 0 and a positive denominator for
    //    every i, so each p_i stays strictly positive and log() is safe.
    var p = [Double](repeating: 1.0, count: n)
    for _ in 0..<bradleyTerryMaxIterations {
        var pNext = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var denominator = 0.0
            for j in 0..<n where j != i {
                let nij = pairCount[i][j]
                if nij != 0 { denominator += nij / (p[i] + p[j]) }
            }
            pNext[i] = wins[i] / denominator
        }
        // Renormalise to geometric mean 1: divide by exp(mean(log p)).
        var logSum = 0.0
        for value in pNext { logSum += log(value) }
        let geometricMean = exp(logSum / Double(n))
        for i in 0..<n { pNext[i] /= geometricMean }
        // Convergence: largest relative change over the sweep.
        var maxRelativeChange = 0.0
        for i in 0..<n {
            let change = abs(pNext[i] - p[i]) / p[i]
            if change > maxRelativeChange { maxRelativeChange = change }
        }
        p = pNext
        if maxRelativeChange < bradleyTerryEpsilon { break }
    }

    // 6 & 7. Convert to the log strength scale and attach a 95% CI.
    //
    //   strength_i = log(p_i)  — additive, gauge-fixed to sum zero.
    //
    //   The Fisher information for the BT model is a graph Laplacian
    //   (singular, reflecting the additive non-identifiability). Its
    //   diagonal is
    //        I_ii = Σ_{j≠i} n_ij · π_ij · π_ji,
    //   where π_ij = p_i/(p_i+p_j) is the modelled probability i beats
    //   j and π_ij·π_ji is the Bernoulli variance of one comparison.
    //   We take the DIAGONAL standard error SE_i = 1/√I_ii — the
    //   independence approximation, which needs no matrix inversion and
    //   so is deterministic and dependency-free, exactly as the mission
    //   prescribes. It treats each strength as if estimated
    //   independently; because it ignores the (positive) off-diagonal
    //   coupling it is a mild UNDER-estimate of the true marginal SE
    //   (for a Laplacian, [I⁻¹]_ii ≥ 1/I_ii). Strong connectivity makes
    //   every π strictly inside (0,1) and I_ii > 0, so SE is finite.
    //   No bootstrap is used (it would introduce a seeding/determinism
    //   surface the mission forbids).
    var scores = [BradleyTerryScore]()
    scores.reserveCapacity(n)
    for i in 0..<n {
        let strength = log(p[i])
        var information = 0.0
        for j in 0..<n where j != i {
            let nij = pairCount[i][j]
            if nij == 0 { continue }
            let total = p[i] + p[j]
            let piWin = p[i] / total
            let pjWin = p[j] / total
            information += nij * piWin * pjWin
        }
        let standardError = 1.0 / information.squareRoot()
        let halfWidth = bradleyTerryZ95 * standardError
        scores.append(
            BradleyTerryScore(
                competitorID: ids[i],
                strength: strength,
                confidenceLow: strength - halfWidth,
                confidenceHigh: strength + halfWidth
            )
        )
    }

    // 8. Rank strongest first; break ties by ascending ID so the order
    //    is total and deterministic even when strengths coincide.
    scores.sort { lhs, rhs in
        if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
        return lhs.competitorID < rhs.competitorID
    }

    // Emit Bradley-Terry update activity. Date() is read internally at
    // each report call — not caller-supplied and not once at the boundary
    // (two metric reports, two Date() reads). Factory-level side-effect
    // permitted per the determinism contract: the BT math itself uses no
    // clock. When monitoring is off, zero cost.
    //
    // `neuronkit.tournament.bt_update`: one counter per completed fit.
    // `neuronkit.tournament.competitor_count`: n competitors ranked.
    // Both are metadata-only — no content crosses the telemetry boundary
    // (GUI §4.4 Activity binds tournament-scoring activity to this metric).
    Intellectus.report(.metric(
        name: "neuronkit.tournament.bt_update",
        value: 1.0,
        tags: ["competitor_count": "\(scores.count)"],
        ts: Date().timeIntervalSince1970
    ))
    Intellectus.report(.metric(
        name: "neuronkit.tournament.competitor_count",
        value: Double(scores.count),
        tags: [:],
        ts: Date().timeIntervalSince1970
    ))

    return scores
}

/// Returns whether the directed win graph (edge `i → j` when
/// `winEdge[i][j]`) is strongly connected — every vertex reachable from
/// every other.
///
/// Uses the single-source equivalence: a digraph is strongly connected
/// iff, from any one vertex `v`, all vertices are reachable from `v`
/// AND `v` is reachable from all vertices. The latter is checked by
/// reachability on the transposed graph. Two integer-indexed traversals
/// from vertex 0; no recursion, no hashing, fully deterministic.
private func isStronglyConnected(winEdge: [[Bool]], count n: Int) -> Bool {
    if n <= 1 { return true }
    // Forward edges: i → j when i beat j.
    let forwardReach = reachableCount(from: 0, count: n) { from, to in winEdge[from][to] }
    if forwardReach != n { return false }
    // Transposed edges: j → i when i beat j (i.e. who-beat-`from`).
    let reverseReach = reachableCount(from: 0, count: n) { from, to in winEdge[to][from] }
    return reverseReach == n
}

/// Counts vertices reachable from `start` over the edge relation
/// `hasEdge`. Iterative depth-first traversal with a visited array;
/// no recursion so it cannot overflow on large competitor sets.
private func reachableCount(
    from start: Int,
    count n: Int,
    hasEdge: (Int, Int) -> Bool
) -> Int {
    var visited = [Bool](repeating: false, count: n)
    var stack = [start]
    visited[start] = true
    var reached = 1
    while let vertex = stack.popLast() {
        for neighbour in 0..<n where !visited[neighbour] && hasEdge(vertex, neighbour) {
            visited[neighbour] = true
            reached += 1
            stack.append(neighbour)
        }
    }
    return reached
}
