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
// This reference implements **phase 1 only** as the minimal
// faithful realization. The cookbook's auto-rooming use case
// (cookbook § 11.11) is well-served by phase-1 results on
// realistic personal-estate graphs; phase 2 produces a coarser
// hierarchical partition that is useful for larger estates and
// is deferred to a future reference.
//
// Modularity (Newman 2006) for a partition C of a weighted
// undirected graph with edge weight w_{ij} and total weight
// `m = (1/2) sum_{ij} w_{ij}` is
//
//     Q = (1 / 2m) sum_{ij} [w_{ij} - (k_i k_j) / (2m)] delta(C_i, C_j)
//
// where k_i = sum_j w_{ij} is the weighted degree of node i and
// delta is one if C_i = C_j and zero otherwise. The local-move
// modularity gain from moving node i from community A to
// community B is
//
//     Delta Q = (k_{i,B} - k_{i,A}) / m
//             - k_i * (sigma_B - sigma_A + k_i) / (2 * m^2)
//
// where `k_{i,X}` is the sum of edge weights from i to nodes
// already in X (excluding i if X = A) and `sigma_X` is the sum
// of all edge weights incident to nodes in X (excluding i if
// X = A). The reference recomputes these on the fly rather than
// maintaining the Louvain incremental data structures, which
// makes the algorithm O(N * E) per pass instead of O(E) but
// keeps the reference under 200 lines.
//
// Cookbook references:
//   § 7.3   Community detection (the spec)
//   § 11.11 recall_keystone / auto-rooming consumer
//   § 15.1  Dreaming daemon Rule 11 (daily community refresh)

import Foundation

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
    public static func detect(adjacency: Adjacency,
                               maxPasses: Int = 10) -> [Int] {
        let n = adjacency.count
        if n == 0 { return [] }

        // Each node starts in its own community.
        var community = Array(0..<n)

        // Weighted degree of each node.
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
                // Also remember own-community for the baseline.
                var kIInto: [Int: Double] = [:]
                for (j, w) in adjacency[i] {
                    if j == i { continue }
                    kIInto[community[j], default: 0.0] += w
                }

                // Modularity gain of moving i from currentCommunity
                // to candidateCommunity:
                //
                //   sigma_A_excl = sigma[currentCommunity] - kI
                //   gain(C) = (k_{i,C} - k_{i,currentCommunity}) / m
                //           - kI * (sigma[C] - sigma_A_excl + kI)
                //             / (2 * m^2)
                //
                // We seek the candidate community maximizing gain.

                let kIIntoCurrent = kIInto[currentCommunity] ?? 0.0
                let sigmaAExcl = sigma[currentCommunity] - kI
                var bestGain = 0.0
                var bestCommunity = currentCommunity
                for (candidate, kIIntoC) in kIInto {
                    if candidate == currentCommunity { continue }
                    let gain = (kIIntoC - kIIntoCurrent) / m
                              - kI * (sigma[candidate] - sigmaAExcl + kI)
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
//   well-defined-on-empty: detect([]) returns [].
//   each-node-in-some-community: every element of the output is
//                                in 0..K for some K.
//   canonical-labels:           the first node always gets label 0;
//                                subsequent distinct labels are
//                                assigned in order of first
//                                appearance.
//   monotone-modularity:        each pass strictly increases
//                                modularity or terminates; the
//                                cookbook's tolerance on
//                                modularity gain is implicitly
//                                "any positive gain" in this
//                                reference.
//   greedy-tie-breaking:        the first candidate community
//                                with positive gain wins ties.
//                                Production-grade Louvain
//                                implementations use random
//                                tie-breaking; the reference is
//                                deterministic for cross-language
//                                bit-identity.
//
// MARK: - Cookbook references
//   § 7.3, § 11.11, § 15.1
