// CommunityDetection.swift
//
// Community detection on the estate graph, per cookbook § 7.3.
//
// The cookbook commits to the Louvain method [Blondel et al.
// 2008] for community detection. Louvain proceeds in two phases:
//
//   Phase 1: Local move.   For each node in some order, consider
//                          moving it to a neighboring community
//                          that maximizes modularity gain.
//                          Repeat until no improving move remains.
//   Phase 2: Aggregation.  Build a new graph whose nodes are the
//                          phase-1 communities and whose edges
//                          sum the within- and between-community
//                          weights. Recurse from phase 1.
//
// This reference implements **both phases**. `detect` runs
// phase 1 only and is the per-level engine; `detectFull` wraps
// it in the phase-2 aggregation loop (condense communities into
// supernodes, recurse, project labels down) and adds a
// resolution parameter (Reichardt-Bornholdt gamma).
//
// Phase 1 alone has a documented pair-locking limitation: on a
// graph dominated by strongly-bonded pairs (tunnel bonds, w=1.0)
// with weaker star bonds (lattice bonds, w=0.2), local-move can
// never pull a member out of its pair — leaving costs 1.0 to
// gain 0.2, strictly negative modularity. Aggregation collapses
// each pair into a supernode whose internal weight becomes a
// self-loop, but the self-loop still inflates the supernode's
// degree and therefore the gain penalty: at resolution 1.0 the
// pair partition IS the modularity optimum and correctly
// survives phase 2. The cure for the pathology is the resolution
// parameter: gamma scales only the degree-penalty term, and a
// supernode with degree k and edge weight w into a target
// community merges whenever gamma < w / k regardless of graph
// size (scale-invariant absorption bound). Consumers that need
// star-of-pairs collapse (NeuronKit topology/constellation) pass
// gamma = 0.05 < 0.2/2.2; classical Louvain is gamma = 1.0.
//
// Modularity (Newman 2006) for a partition C of a weighted
// undirected graph with edge weight w_{ij} and total weight
// `m = (1/2) sum_{ij} w_{ij}` is
//
//     Q = (1 / 2m) sum_{ij} [w_{ij} - (k_i k_j) / (2m)] delta(C_i, C_j)
//
// where k_i = sum_j w_{ij} is the weighted degree of node i and
// delta is one if C_i = C_j and zero otherwise. The local-move
// gain from moving node i from community A to community B, with
// resolution gamma, is
//
//     Delta Q = (k_{i,B} - k_{i,A}) / m
//             - gamma * k_i * (sigma_B - sigma_A + k_i) / (2 * m^2)
//
// where `k_{i,X}` is the sum of edge weights from i to nodes
// already in X (excluding i if X = A) and `sigma_X` is the sum
// of all edge weights incident to nodes in X (excluding i if
// X = A). gamma = 1.0 reproduces classical modularity exactly
// (1.0 * x == x in IEEE 754, so `detect` results are bit-stable
// across this refactor). The reference recomputes these on the
// fly rather than maintaining the Louvain incremental data
// structures, which makes the algorithm O(N * E) per pass
// instead of O(E) but keeps the reference compact.
//
// Cookbook references:
//   § 7.3   Community detection (the spec)
//   § 11.11 recall_keystone / auto-rooming consumer
//   § 15.1  Dreaming daemon Rule 11 (daily community refresh)

import Foundation
import IntellectusLib

public enum CommunityDetection {

    /// Sparse adjacency over an undirected weighted graph.
    /// `adjacency[i]` is the list of (neighbor, weight) pairs.
    /// The caller is responsible for symmetry: edges (i, j, w)
    /// must appear in both `adjacency[i]` and `adjacency[j]` with
    /// the same `w`. Self-loops are permitted and contribute to
    /// the node's weighted degree.
    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]

    /// Run Louvain phase 1 (local-move) on the supplied graph.
    /// Returns a community label for each node, 0..K-1 where K
    /// is the number of communities discovered.
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals.communityAssignment` with the number of
    /// communities found, tagged by estate and node count. The emit
    /// is a no-op (single atomic-bool load) when monitoring is off.
    ///
    /// - Parameters:
    ///   - adjacency: The weighted adjacency list.
    ///   - maxPasses: Maximum Louvain phase-1 passes (default 10).
    ///   - estate: Estate identifier tag for VizGraph telemetry. Pass
    ///             the estate ID known at the call site. Empty string
    ///             suppresses the estate tag (monitoring still no-ops
    ///             when disabled regardless of this value).
    ///   - ts: Caller-supplied epoch seconds for telemetry. Never read
    ///         a clock inside SubstrateML; the caller provides `ts`.
    public static func detect(adjacency: Adjacency,
                               maxPasses: Int = 10,
                               estate: String = "",
                               ts: Double = 0) -> [Int] {
        let n = adjacency.count
        if n == 0 { return [] }
        // Degenerate zero-weight graph: identity labeling, no emit —
        // mirrors the historical early-return so telemetry behavior is
        // unchanged by the detectCore refactor.
        if totalEdgeWeight(adjacency) < 1.0e-30 { return Array(0..<n) }

        let result = detectCore(adjacency: adjacency,
                                maxPasses: maxPasses,
                                resolution: 1.0)

        emitCommunityAssignment(result: result, nodeCount: n,
                                estate: estate, ts: ts)
        return result
    }

    /// Run full Louvain — phase 1 plus the phase-2 aggregation loop —
    /// on the supplied graph. Returns a community label for each node,
    /// 0..K-1 in order of first appearance.
    ///
    /// Each level runs phase-1 local-move to convergence, then condenses
    /// the partition into a supernode graph (intra-community weight
    /// becomes a supernode self-loop; inter-community weight becomes a
    /// supernode edge) and recurses until a level produces no merges
    /// (K == node count) or `maxLevels` is exhausted.
    ///
    /// VizGraph telemetry: emits exactly ONE
    /// `VizGraphSignals.communityAssignment` signal for the FINAL
    /// partition at the outer boundary, no matter how many levels run —
    /// the per-level cores are non-emitting. Same tag set as `detect`.
    ///
    /// - Parameters:
    ///   - adjacency: The weighted adjacency list (symmetric; self-loops
    ///                permitted, counted once toward degree).
    ///   - maxLevels: Maximum aggregation levels (default 10; typical
    ///                convergence is 2–4 levels).
    ///   - maxPasses: Maximum phase-1 passes per level (default 10).
    ///   - resolution: Reichardt-Bornholdt gamma scaling the
    ///                 degree-penalty term of the gain. 1.0 (default) is
    ///                 classical Louvain. A supernode with degree k and
    ///                 edge weight w into a target community merges
    ///                 whenever gamma < w/k — scale-invariant — so small
    ///                 gamma absorbs strongly-paired supernodes into hub
    ///                 communities without gluing large continents
    ///                 together (their thresholds shrink as w_bridge/m).
    ///   - estate: Estate identifier tag for VizGraph telemetry.
    ///   - ts: Caller-supplied epoch seconds for telemetry. Never read
    ///         a clock inside SubstrateML; the caller provides `ts`.
    public static func detectFull(adjacency: Adjacency,
                                  maxLevels: Int = 10,
                                  maxPasses: Int = 10,
                                  resolution: Double = 1.0,
                                  estate: String = "",
                                  ts: Double = 0) -> [Int] {
        let n = adjacency.count
        if n == 0 { return [] }
        // Degenerate zero-weight graph: identity labeling, no emit —
        // same contract as detect.
        if totalEdgeWeight(adjacency) < 1.0e-30 { return Array(0..<n) }

        // Level 0: phase 1 on the input graph. Labels are canonical
        // (0..K-1 by first appearance), which makes the label double as
        // the supernode index for condensation.
        var globalLabels = detectCore(adjacency: adjacency,
                                      maxPasses: maxPasses,
                                      resolution: resolution)
        var levelGraph = adjacency
        var levelLabels = globalLabels

        for _ in 0..<maxLevels {
            // Canonical labels ⇒ K = max + 1. K == node count means the
            // level produced no merges: the partition is stable, stop.
            let k = (levelLabels.max() ?? -1) + 1
            if k == levelGraph.count { break }

            let condensed = condense(levelGraph, labels: levelLabels, communityCount: k)
            let superLabels = detectCore(adjacency: condensed,
                                         maxPasses: maxPasses,
                                         resolution: resolution)

            // Project the supernode partition down to original nodes.
            // Composition of canonical maps is canonical, so globalLabels
            // stays a valid supernode index for the next level.
            for i in 0..<globalLabels.count {
                globalLabels[i] = superLabels[globalLabels[i]]
            }
            levelGraph = condensed
            levelLabels = superLabels
        }

        let result = canonicalize(globalLabels)
        emitCommunityAssignment(result: result, nodeCount: n,
                                estate: estate, ts: ts)
        return result
    }

    /// Sum of all adjacency entry weights (= 2m for a symmetric graph
    /// where self-loops appear once).
    private static func totalEdgeWeight(_ adjacency: Adjacency) -> Double {
        var total = 0.0
        for row in adjacency {
            for (_, w) in row { total += w }
        }
        return total
    }

    /// Phase-1 local-move engine shared by `detect` and `detectFull`.
    /// Non-emitting: telemetry is the caller's responsibility, which is
    /// what keeps `detectFull` at exactly one signal across all levels.
    /// Returns canonical labels.
    private static func detectCore(adjacency: Adjacency,
                                   maxPasses: Int,
                                   resolution: Double) -> [Int] {
        let n = adjacency.count
        if n == 0 { return [] }

        // Each node starts in its own community.
        var community = Array(0..<n)

        // Weighted degree of each node. Self-loops contribute their
        // weight once (they appear once in the adjacency row).
        var degree = [Double](repeating: 0.0, count: n)
        var twoM = 0.0
        for i in 0..<n {
            var d = 0.0
            for (_, w) in adjacency[i] { d += w }
            degree[i] = d
            twoM += d
        }
        if twoM < 1.0e-30 { return community }  // disconnected
        let m = twoM / 2.0

        // Sum of degrees in each community (sigma).
        var sigma = degree

        // Phase 1 loop: iterate until no improving move.
        for _ in 0..<maxPasses {
            var improved = false
            for i in 0..<n {
                let currentCommunity = community[i]
                let kI = degree[i]

                // Compute k_{i, C} for every neighbor community.
                // Self-loops are excluded: they belong to the node, not
                // to any candidate move.
                var kIInto: [Int: Double] = [:]
                for (j, w) in adjacency[i] {
                    if j == i { continue }
                    kIInto[community[j], default: 0.0] += w
                }

                // Modularity gain of moving i from currentCommunity
                // to candidateCommunity, with resolution gamma:
                //
                //   sigma_A_excl = sigma[currentCommunity] - kI
                //   gain(C) = (k_{i,C} - k_{i,currentCommunity}) / m
                //           - gamma * kI * (sigma[C] - sigma_A_excl + kI)
                //             / (2 * m^2)
                //
                // We seek the candidate community maximizing gain.
                // Candidates are evaluated in ascending community-label
                // order so that gain TIES resolve to the lowest label in
                // both language legs — Swift Dictionary and Rust HashMap
                // iteration orders are arbitrary (Rust's is randomized
                // per process), and an order-dependent tie-break would
                // break cross-leg bit-identity.

                let kIIntoCurrent = kIInto[currentCommunity] ?? 0.0
                let sigmaAExcl = sigma[currentCommunity] - kI
                var bestGain = 0.0
                var bestCommunity = currentCommunity
                for candidate in kIInto.keys.sorted() {
                    if candidate == currentCommunity { continue }
                    let kIIntoC = kIInto[candidate]!
                    let gain = (kIIntoC - kIIntoCurrent) / m
                              - resolution * kI * (sigma[candidate] - sigmaAExcl + kI)
                                / (2.0 * m * m)
                    if gain > bestGain {
                        bestGain = gain
                        bestCommunity = candidate
                    }
                }

                if bestCommunity != currentCommunity {
                    sigma[currentCommunity] -= kI
                    sigma[bestCommunity] += kI
                    community[i] = bestCommunity
                    improved = true
                }
            }
            if !improved { break }
        }

        // Renumber communities to 0..K-1 for canonical output.
        return canonicalize(community)
    }

    /// Phase-2 condensation: collapse each community into a supernode.
    /// `labels` must be canonical (0..communityCount-1) — the label IS
    /// the supernode index.
    ///
    /// Weight bookkeeping preserves total degree exactly: every adjacency
    /// entry (i → j, w) is accumulated once into row labels[i], column
    /// labels[j]. A symmetric internal edge therefore lands TWICE on the
    /// supernode self-loop (once from each endpoint), which is the
    /// degree-preserving convention — supernode degree equals the sum of
    /// member degrees, and 2m is unchanged across levels, so modularity
    /// at level L+1 equals modularity of the projected partition at
    /// level L. Original self-loops (stored once) accumulate once.
    ///
    /// Determinism: accumulation runs in ascending node order with each
    /// row in stored order (identical in both legs), and each supernode's
    /// adjacency list is emitted in ascending neighbor order.
    private static func condense(_ adjacency: Adjacency,
                                 labels: [Int],
                                 communityCount: Int) -> Adjacency {
        var rows = [[Int: Double]](repeating: [:], count: communityCount)
        for i in 0..<adjacency.count {
            let a = labels[i]
            for (j, w) in adjacency[i] {
                rows[a][labels[j], default: 0.0] += w
            }
        }
        var condensed: Adjacency = []
        condensed.reserveCapacity(communityCount)
        for a in 0..<communityCount {
            let entries = rows[a].keys.sorted().map { b in
                (neighbor: b, weight: rows[a][b]!)
            }
            condensed.append(entries)
        }
        return condensed
    }

    /// VizGraph emit: community.assignment signal at the result boundary.
    /// The node→community partition is complete; the Topology view can
    /// use community labels to colour-cluster nodes.
    ///
    /// Off-path when monitoring is disabled: single Atomic<Bool> load
    /// + branch (~1 ns). The autoclosure is NEVER evaluated when off,
    /// so community count arithmetic only runs when monitoring is on.
    private static func emitCommunityAssignment(result: [Int],
                                                nodeCount: Int,
                                                estate: String,
                                                ts: Double) {
        Intellectus.report({
            let communityCount = Set(result).count
            return .metric(
                name: VizGraphSignals.communityAssignment,
                value: Double(communityCount),
                tags: [
                    "estate": estate,
                    "node_count": "\(nodeCount)",
                    "community_count": "\(communityCount)",
                ],
                ts: ts
            )
        }())
    }

    /// Renumber labels so that the first node has label 0, the
    /// next distinct label encountered is 1, and so on. This
    /// makes the output stable across implementations regardless
    /// of the original integer labels used internally.
    public static func canonicalize(_ labels: [Int]) -> [Int] {
        var renumber: [Int: Int] = [:]
        var next = 0
        var out = [Int](repeating: 0, count: labels.count)
        for (i, lab) in labels.enumerated() {
            if let r = renumber[lab] {
                out[i] = r
            } else {
                renumber[lab] = next
                out[i] = next
                next += 1
            }
        }
        return out
    }
}

// MARK: - Properties
//
//   well-defined-on-empty: detect([]) and detectFull([]) return [].
//   each-node-in-some-community: every element of the output is
//                                in 0..K for some K.
//   canonical-labels:           the first node always gets label 0;
//                                subsequent distinct labels are
//                                assigned in order of first
//                                appearance. detectFull canonicalizes
//                                at EVERY level, so the level label
//                                doubles as the supernode index for
//                                condensation.
//   monotone-modularity:        each pass strictly increases
//                                (resolution-scaled) modularity or
//                                terminates; the tolerance on
//                                modularity gain is implicitly
//                                "any positive gain" in this
//                                reference. The aggregation loop
//                                terminates when a level produces no
//                                merges (K == node count) or maxLevels
//                                is reached.
//   greedy-tie-breaking:        candidate communities are evaluated
//                                in ascending label order; gain ties
//                                resolve to the lowest label. This is
//                                deterministic in both language legs —
//                                hash-map iteration order (randomized
//                                in Rust, arbitrary in Swift) never
//                                reaches the comparison. Production-
//                                grade Louvain implementations use
//                                random tie-breaking; the reference is
//                                deterministic for cross-language
//                                bit-identity.
//   deterministic-condensation: condensation accumulates in ascending
//                                node order (each row in stored order)
//                                and emits each supernode's adjacency
//                                in ascending neighbor order; internal
//                                weight lands on the supernode
//                                self-loop twice (degree-preserving),
//                                so 2m is invariant across levels.
//   resolution-neutrality:      detect == detectCore at gamma 1.0 and
//                                detectFull(resolution: 1.0) is
//                                classical Louvain; 1.0 * x == x in
//                                IEEE 754, so the resolution refactor
//                                cannot perturb classical results.
//
// MARK: - Cookbook references
//   § 7.3, § 11.11, § 15.1
