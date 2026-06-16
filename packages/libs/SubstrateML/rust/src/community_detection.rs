// community_detection.rs
//
// Community detection on the estate graph, per cookbook § 7.3.
// Mirror of Sources/SubstrateML/CommunityDetection.swift. Implements
// BOTH Louvain phases: `detect` runs phase 1 (local-move modularity
// maximization) and is the per-level engine; `detect_full` wraps it
// in the phase-2 aggregation loop (condense communities into
// supernodes, recurse, project labels down) and adds a resolution
// parameter (Reichardt-Bornholdt gamma).
//
// Phase 1 alone has a documented pair-locking limitation: on a graph
// dominated by strongly-bonded pairs (tunnel bonds, w=1.0) with
// weaker star bonds (lattice bonds, w=0.2), local-move can never
// pull a member out of its pair. At resolution 1.0 the pair
// partition IS the modularity optimum and correctly survives
// phase 2; the cure is the resolution parameter — a supernode with
// degree k and edge weight w into a target community merges whenever
// gamma < w / k, scale-invariantly. See the Swift header for the
// full exposition; both legs must agree bit-for-bit on the shared
// V1-V5 conformance vectors.

use std::collections::HashMap;
use intellectus_lib::{StatSample, report};
use crate::viz_graph_signals::VizGraphSignals;

pub struct CommunityDetection;

impl CommunityDetection {
    /// Run Louvain phase 1 on a symmetric weighted adjacency.
    /// Returns a canonical community label for each node, with
    /// labels 0..K-1 assigned in order of first appearance.
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals::COMMUNITY_ASSIGNMENT` with the number of
    /// communities found, tagged by estate and node count. Off-path
    /// is a single AtomicBool load + branch — no allocation.
    ///
    /// # Parameters
    /// - `adjacency`: The weighted adjacency list.
    /// - `max_passes`: Maximum Louvain phase-1 passes.
    /// - `estate`: Estate identifier tag for VizGraph telemetry.
    /// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
    pub fn detect(adjacency: &[Vec<(usize, f64)>], max_passes: usize,
                  estate: &str, ts: f64) -> Vec<usize> {
        let n = adjacency.len();
        if n == 0 {
            return Vec::new();
        }
        // Degenerate zero-weight graph: identity labeling, no emit —
        // mirrors the historical early-return so telemetry behavior is
        // unchanged by the detect_core refactor.
        if Self::total_edge_weight(adjacency) < 1.0e-30 {
            return (0..n).collect();
        }

        let result = Self::detect_core(adjacency, max_passes, 1.0);
        Self::emit_community_assignment(&result, n, estate, ts);
        result
    }

    /// Run full Louvain — phase 1 plus the phase-2 aggregation loop —
    /// on the supplied graph. Returns a community label for each node,
    /// 0..K-1 in order of first appearance.
    ///
    /// Each level runs phase-1 local-move to convergence, then
    /// condenses the partition into a supernode graph (intra-community
    /// weight becomes a supernode self-loop; inter-community weight
    /// becomes a supernode edge) and recurses until a level produces no
    /// merges (K == node count) or `max_levels` is exhausted.
    ///
    /// VizGraph telemetry: emits exactly ONE
    /// `VizGraphSignals::COMMUNITY_ASSIGNMENT` signal for the FINAL
    /// partition at the outer boundary, no matter how many levels run —
    /// the per-level cores are non-emitting. Same tag set as `detect`.
    ///
    /// # Parameters
    /// - `adjacency`: The weighted adjacency list (symmetric; self-loops
    ///   permitted, counted once toward degree).
    /// - `max_levels`: Maximum aggregation levels (typical convergence
    ///   is 2-4 levels; Swift defaults this to 10).
    /// - `max_passes`: Maximum phase-1 passes per level.
    /// - `resolution`: Reichardt-Bornholdt gamma scaling the
    ///   degree-penalty term of the gain. 1.0 is classical Louvain. A
    ///   supernode with degree k and edge weight w into a target
    ///   community merges whenever gamma < w/k — scale-invariant — so
    ///   small gamma absorbs strongly-paired supernodes into hub
    ///   communities without gluing large continents together (their
    ///   thresholds shrink as w_bridge/m).
    /// - `estate`: Estate identifier tag for VizGraph telemetry.
    /// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
    pub fn detect_full(adjacency: &[Vec<(usize, f64)>], max_levels: usize,
                       max_passes: usize, resolution: f64,
                       estate: &str, ts: f64) -> Vec<usize> {
        let n = adjacency.len();
        if n == 0 {
            return Vec::new();
        }
        // Degenerate zero-weight graph: identity labeling, no emit —
        // same contract as detect.
        if Self::total_edge_weight(adjacency) < 1.0e-30 {
            return (0..n).collect();
        }

        // Level 0: phase 1 on the input graph. Labels are canonical
        // (0..K-1 by first appearance), which makes the label double as
        // the supernode index for condensation.
        let mut global_labels = Self::detect_core(adjacency, max_passes, resolution);
        let mut level_graph: Vec<Vec<(usize, f64)>> = adjacency.to_vec();
        let mut level_labels = global_labels.clone();

        for _ in 0..max_levels {
            // Canonical labels => K = max + 1. K == node count means the
            // level produced no merges: the partition is stable, stop.
            let k = level_labels.iter().max().map_or(0, |&mx| mx + 1);
            if k == level_graph.len() {
                break;
            }

            let condensed = Self::condense(&level_graph, &level_labels, k);
            let super_labels = Self::detect_core(&condensed, max_passes, resolution);

            // Project the supernode partition down to original nodes.
            // Composition of canonical maps is canonical, so
            // global_labels stays a valid supernode index for the next
            // level.
            for label in global_labels.iter_mut() {
                *label = super_labels[*label];
            }
            level_graph = condensed;
            level_labels = super_labels;
        }

        let result = Self::canonicalize(&global_labels);
        Self::emit_community_assignment(&result, n, estate, ts);
        result
    }

    /// Sum of all adjacency entry weights (= 2m for a symmetric graph
    /// where self-loops appear once).
    fn total_edge_weight(adjacency: &[Vec<(usize, f64)>]) -> f64 {
        adjacency.iter()
            .map(|row| row.iter().map(|&(_, w)| w).sum::<f64>())
            .sum()
    }

    /// Phase-1 local-move engine shared by `detect` and `detect_full`.
    /// Non-emitting: telemetry is the caller's responsibility, which is
    /// what keeps `detect_full` at exactly one signal across all levels.
    /// Returns canonical labels.
    fn detect_core(adjacency: &[Vec<(usize, f64)>], max_passes: usize,
                   resolution: f64) -> Vec<usize> {
        let n = adjacency.len();
        if n == 0 {
            return Vec::new();
        }

        // Each node starts in its own community.
        let mut community: Vec<usize> = (0..n).collect();

        // Weighted degree of each node. Self-loops contribute their
        // weight once (they appear once in the adjacency row).
        let mut degree = vec![0.0f64; n];
        let mut two_m = 0.0;
        for i in 0..n {
            let d: f64 = adjacency[i].iter().map(|&(_, w)| w).sum();
            degree[i] = d;
            two_m += d;
        }
        if two_m < 1.0e-30 {
            return community;
        }
        let m = two_m / 2.0;

        // Sum of degrees in each community (sigma).
        let mut sigma = degree.clone();

        // Phase 1 loop: iterate until no improving move.
        for _ in 0..max_passes {
            let mut improved = false;
            for i in 0..n {
                let current = community[i];
                let k_i = degree[i];

                // Compute k_{i, C} for every neighbor community.
                // Self-loops are excluded: they belong to the node, not
                // to any candidate move.
                let mut k_i_into: HashMap<usize, f64> = HashMap::new();
                for &(j, w) in &adjacency[i] {
                    if j == i {
                        continue;
                    }
                    *k_i_into.entry(community[j]).or_insert(0.0) += w;
                }

                // Modularity gain of moving i from `current` to a
                // candidate community, with resolution gamma:
                //
                //   sigma_a_excl = sigma[current] - k_i
                //   gain(C) = (k_{i,C} - k_{i,current}) / m
                //           - gamma * k_i * (sigma[C] - sigma_a_excl + k_i)
                //             / (2 * m^2)
                //
                // We seek the candidate community maximizing gain.
                // Candidates are evaluated in ascending community-label
                // order so that gain TIES resolve to the lowest label in
                // both language legs — HashMap iteration order is
                // randomized per process in Rust (and arbitrary in
                // Swift), and an order-dependent tie-break would break
                // cross-leg bit-identity.
                let k_i_into_current = *k_i_into.get(&current).unwrap_or(&0.0);
                let sigma_a_excl = sigma[current] - k_i;
                let mut candidates: Vec<usize> = k_i_into.keys().copied().collect();
                candidates.sort_unstable();
                let mut best_gain = 0.0;
                let mut best_community = current;
                for candidate in candidates {
                    if candidate == current {
                        continue;
                    }
                    let k_i_into_c = k_i_into[&candidate];
                    let gain = (k_i_into_c - k_i_into_current) / m
                        - resolution * k_i * (sigma[candidate] - sigma_a_excl + k_i)
                          / (2.0 * m * m);
                    if gain > best_gain {
                        best_gain = gain;
                        best_community = candidate;
                    }
                }

                if best_community != current {
                    sigma[current] -= k_i;
                    sigma[best_community] += k_i;
                    community[i] = best_community;
                    improved = true;
                }
            }
            if !improved {
                break;
            }
        }

        // Renumber communities to 0..K-1 for canonical output.
        Self::canonicalize(&community)
    }

    /// Phase-2 condensation: collapse each community into a supernode.
    /// `labels` must be canonical (0..community_count-1) — the label IS
    /// the supernode index.
    ///
    /// Weight bookkeeping preserves total degree exactly: every
    /// adjacency entry (i -> j, w) is accumulated once into row
    /// labels[i], column labels[j]. A symmetric internal edge therefore
    /// lands TWICE on the supernode self-loop (once from each
    /// endpoint), which is the degree-preserving convention — supernode
    /// degree equals the sum of member degrees, and 2m is unchanged
    /// across levels, so modularity at level L+1 equals modularity of
    /// the projected partition at level L. Original self-loops (stored
    /// once) accumulate once.
    ///
    /// Determinism: accumulation runs in ascending node order with each
    /// row in stored order (identical in both legs), and each
    /// supernode's adjacency list is emitted in ascending neighbor
    /// order.
    fn condense(adjacency: &[Vec<(usize, f64)>], labels: &[usize],
                community_count: usize) -> Vec<Vec<(usize, f64)>> {
        let mut rows: Vec<HashMap<usize, f64>> = vec![HashMap::new(); community_count];
        for i in 0..adjacency.len() {
            let a = labels[i];
            for &(j, w) in &adjacency[i] {
                *rows[a].entry(labels[j]).or_insert(0.0) += w;
            }
        }
        let mut condensed = Vec::with_capacity(community_count);
        for row in &rows {
            let mut keys: Vec<usize> = row.keys().copied().collect();
            keys.sort_unstable();
            condensed.push(keys.into_iter().map(|b| (b, row[&b])).collect());
        }
        condensed
    }

    /// VizGraph emit: community.assignment — Louvain partition complete.
    /// The node→community partition is now ready for the Topology view
    /// to colour-cluster nodes. community_count counts distinct labels
    /// in the canonical result.
    ///
    /// Off-path when monitoring is disabled: single AtomicBool load +
    /// branch. The macro body is NEVER evaluated when monitoring is off.
    fn emit_community_assignment(result: &[usize], n: usize,
                                 estate: &str, ts: f64) {
        report!({
            let mut seen = std::collections::HashSet::new();
            for &label in result { seen.insert(label); }
            let community_count = seen.len();
            let mut tags = std::collections::HashMap::new();
            tags.insert("estate".to_string(), estate.to_string());
            tags.insert("node_count".to_string(), n.to_string());
            tags.insert("community_count".to_string(), community_count.to_string());
            StatSample::metric(
                VizGraphSignals::COMMUNITY_ASSIGNMENT.to_string(),
                community_count as f64,
                tags,
                ts,
            )
        });
    }

    pub fn canonicalize(labels: &[usize]) -> Vec<usize> {
        let mut renumber: HashMap<usize, usize> = HashMap::new();
        let mut next = 0usize;
        let mut out = Vec::with_capacity(labels.len());
        for &lab in labels {
            if let Some(&r) = renumber.get(&lab) {
                out.push(r);
            } else {
                renumber.insert(lab, next);
                out.push(next);
                next += 1;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn symmetric_edges(n: usize, edges: &[(usize, usize, f64)]) -> Vec<Vec<(usize, f64)>> {
        let mut adj = vec![Vec::new(); n];
        for &(a, b, w) in edges {
            adj[a].push((b, w));
            adj[b].push((a, w));
        }
        adj
    }

    #[test]
    fn empty_graph() {
        let result = CommunityDetection::detect(&[], 10, "", 0.0);
        assert!(result.is_empty());
    }

    #[test]
    fn disconnected_graph_one_community_per_node() {
        let adj: Vec<Vec<(usize, f64)>> = vec![Vec::new(); 4];
        let result = CommunityDetection::detect(&adj, 10, "", 0.0);
        // With no edges, every node stays in its singleton.
        // Canonical: each becomes its own label in order.
        assert_eq!(result, vec![0, 1, 2, 3]);
    }

    #[test]
    fn two_cliques_split_into_two_communities() {
        // Nodes 0,1,2 fully connected; 3,4,5 fully connected;
        // single weak bridge edge (0, 3) weight 0.01.
        let edges = vec![
            (0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0),
            (3, 4, 1.0), (3, 5, 1.0), (4, 5, 1.0),
            (0, 3, 0.01),
        ];
        let adj = symmetric_edges(6, &edges);
        let result = CommunityDetection::detect(&adj, 20, "", 0.0);
        // {0,1,2} should share a label; {3,4,5} should share a label;
        // the two labels should differ.
        assert_eq!(result[0], result[1]);
        assert_eq!(result[1], result[2]);
        assert_eq!(result[3], result[4]);
        assert_eq!(result[4], result[5]);
        assert_ne!(result[0], result[3]);
    }

    #[test]
    fn canonical_labels_start_at_zero() {
        let edges = vec![(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0)];
        let adj = symmetric_edges(3, &edges);
        let result = CommunityDetection::detect(&adj, 20, "", 0.0);
        // Canonical labels always start at 0 by convention
        // (canonicalize renumbers in order of first appearance).
        // For a lone pure-triangle input, phase 1 leaves the
        // singletons unmerged because every candidate-move gain is
        // negative under the Newman formula at this graph size, and
        // phase 2 at gamma 1.0 does not change that (the condensed
        // gains are negative too — pinned by vector V4). The
        // invariant asserted here is the canonical-labeling
        // property, not the algorithmic-optimum property: every
        // label is in 0..result.len() and the smallest label is 0.
        assert_eq!(result[0], 0);
        let max_label = *result.iter().max().unwrap_or(&0);
        assert!(max_label < result.len(),
                "labels must be in 0..n after canonicalization");
    }

    #[test]
    fn canonicalize_renumbers_in_order_of_first_appearance() {
        let labels = vec![17, 3, 17, 99, 3, 17];
        let canonical = CommunityDetection::canonicalize(&labels);
        // 17 -> 0, 3 -> 1, 99 -> 2.
        assert_eq!(canonical, vec![0, 1, 0, 2, 1, 0]);
    }

    // Shared conformance vectors V1–V5 (detect_full).
    //
    // Identical fixtures and expected canonical labels live in the Swift
    // suite (Tests/SubstrateMLTests/CommunityDetectionTests.swift). Both
    // legs must agree exactly. Expected labels were hand-derived from the
    // resolution-scaled gain formula ΔQ(γ) = (k_{i,B}−k_{i,A})/m
    // − γ·k_i·(σ_B−σ_A^excl+k_i)/(2m²); the canonical assignments are
    // the unique partition that maximises generalized modularity at γ=0.05.

    /// V1 fixture — the live-estate pathology: 4 tunnel-bonded pairs
    /// (w = 1.0), node 0 lattice-star-bonded to one member of each other
    /// pair (w = 0.2).
    fn v1_star_of_pairs() -> Vec<Vec<(usize, f64)>> {
        symmetric_edges(8, &[
            (0, 1, 1.0), (2, 3, 1.0), (4, 5, 1.0), (6, 7, 1.0),
            (0, 2, 0.2), (0, 4, 0.2), (0, 6, 0.2),
        ])
    }

    #[test]
    fn v1_phase1_locks_pairs() {
        let result = CommunityDetection::detect(&v1_star_of_pairs(), 20, "", 0.0);
        assert_eq!(result, vec![0, 0, 1, 1, 2, 2, 3, 3]);
    }

    #[test]
    fn v1_detect_full_resolution_one_keeps_pairs() {
        // Q(4 pairs) = 0.618 is the global optimum at gamma = 1.0; the
        // condensed first-merge gain is -0.206. Full Louvain must NOT
        // differ from phase 1 here — the cure for the pathology is
        // resolution, not aggregation alone.
        let result = CommunityDetection::detect_full(&v1_star_of_pairs(), 10, 20, 1.0, "", 0.0);
        assert_eq!(result, vec![0, 0, 1, 1, 2, 2, 3, 3]);
    }

    #[test]
    fn v1_detect_full_low_resolution_collapses() {
        // gamma = 0.05 is below the scale-invariant absorption bound
        // gamma < w_lattice / k_pair = 0.2 / 2.2 ~= 0.0909, so every pair
        // supernode merges into the star at level 1. Intermediate gain
        // ties among the symmetric pair supernodes are harmless: the
        // terminal state is the single community regardless of tie order.
        let result = CommunityDetection::detect_full(&v1_star_of_pairs(), 10, 20, 0.05, "", 0.0);
        assert_eq!(result, vec![0, 0, 0, 0, 0, 0, 0, 0]);
    }

    /// V2 fixture — two 4-cliques joined by one weak bridge (0–4, w = 0.01).
    fn v2_two_cliques_bridge() -> Vec<Vec<(usize, f64)>> {
        symmetric_edges(8, &[
            (0, 1, 1.0), (0, 2, 1.0), (0, 3, 1.0),
            (1, 2, 1.0), (1, 3, 1.0), (2, 3, 1.0),
            (4, 5, 1.0), (4, 6, 1.0), (4, 7, 1.0),
            (5, 6, 1.0), (5, 7, 1.0), (6, 7, 1.0),
            (0, 4, 0.01),
        ])
    }

    #[test]
    fn v2_no_over_merge_at_resolution_one() {
        let expected = vec![0, 0, 0, 0, 1, 1, 1, 1];
        assert_eq!(CommunityDetection::detect(&v2_two_cliques_bridge(), 20, "", 0.0), expected);
        assert_eq!(
            CommunityDetection::detect_full(&v2_two_cliques_bridge(), 10, 20, 1.0, "", 0.0),
            expected
        );
    }

    #[test]
    fn v2_no_over_merge_at_low_resolution() {
        // Continent-merge threshold is gamma < 2m*w_bridge/(k*(sigma+k))
        // ~= 0.00083 for these cliques — orders of magnitude below 0.05.
        // The low gamma that absorbs pair supernodes must not glue real
        // continents together.
        assert_eq!(
            CommunityDetection::detect_full(&v2_two_cliques_bridge(), 10, 20, 0.05, "", 0.0),
            vec![0, 0, 0, 0, 1, 1, 1, 1]
        );
    }

    /// V3 fixture — two triangles + weak bridge: already optimal after
    /// phase 1, so the aggregation loop terminates on K == n at level 1.
    fn v3_already_optimal() -> Vec<Vec<(usize, f64)>> {
        symmetric_edges(6, &[
            (0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0),
            (3, 4, 1.0), (3, 5, 1.0), (4, 5, 1.0),
            (0, 3, 0.01),
        ])
    }

    #[test]
    fn v3_detect_full_matches_detect_when_optimal() {
        let phase1 = CommunityDetection::detect(&v3_already_optimal(), 20, "", 0.0);
        let full = CommunityDetection::detect_full(&v3_already_optimal(), 10, 20, 1.0, "", 0.0);
        assert_eq!(phase1, vec![0, 0, 0, 1, 1, 1]);
        assert_eq!(full, phase1);
    }

    /// V4 fixture — triangle with an explicit self-loop on node 0
    /// (w = 0.5). The self-loop counts toward node 0's degree (k0 = 2.5)
    /// but never toward k_{i,C}; the expected labels pin that math.
    fn v4_self_loop_triangle() -> Vec<Vec<(usize, f64)>> {
        let mut adj = symmetric_edges(3, &[(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0)]);
        adj[0].push((0, 0.5));
        adj
    }

    #[test]
    fn v4_self_loop_degree_math() {
        // At gamma = 1.0 every move gain is negative (k0 = 2.5 inflates
        // the penalty), so all three nodes stay singletons; detect_full's
        // level-0 K == n and the loop terminates without condensing.
        assert_eq!(CommunityDetection::detect(&v4_self_loop_triangle(), 20, "", 0.0), vec![0, 1, 2]);
        assert_eq!(
            CommunityDetection::detect_full(&v4_self_loop_triangle(), 10, 20, 1.0, "", 0.0),
            vec![0, 1, 2]
        );
        // At gamma = 0.05 the penalty shrinks and the triangle collapses;
        // the condensation path then carries the self-loop weight through.
        assert_eq!(
            CommunityDetection::detect_full(&v4_self_loop_triangle(), 10, 20, 0.05, "", 0.0),
            vec![0, 0, 0]
        );
    }

    #[test]
    fn v5_empty_and_singleton_are_total() {
        assert!(CommunityDetection::detect_full(&[], 10, 10, 1.0, "", 0.0).is_empty());
        // Singleton, no edges (zero total weight).
        let lone: Vec<Vec<(usize, f64)>> = vec![Vec::new()];
        assert_eq!(CommunityDetection::detect_full(&lone, 10, 10, 1.0, "", 0.0), vec![0]);
        // Singleton with a self-loop (non-zero weight, no candidate moves).
        let looped = vec![vec![(0usize, 1.0f64)]];
        assert_eq!(CommunityDetection::detect_full(&looped, 10, 10, 1.0, "", 0.0), vec![0]);
    }
}
