//! Graph-centrality PRODUCER support — the Rust mirror of Swift
//! `NeuronKit/Governor/GraphCentralityProducer.swift`.
//!
//! ─────────────────────────────────────────────────────────────────
//! DO NOT REIMPLEMENT SUBSTRATE MATH.
//!
//! Eigenvalue centrality is a conformance-gated SubstrateML primitive,
//! surfaced through NeuronKit's `keystones` lens. This module is a CADENCE
//! WRAPPER over that oracle: it shapes the estate's structure graph into
//! (node_ids, edges), and the governor duty calls `neuron_kit::keystones`
//! and caches the per-drawer scores. It owns no math.
//! ─────────────────────────────────────────────────────────────────
//!
//! The cache + adjacency builder here must compute the IDENTICAL graph and
//! scores as the Swift port (`GraphCentralityCache` / `GraphCentralityAdjacency`)
//! so a registered cache reads the same `graph` column on both ports.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use genius_locus_kit::GraphCache;
use locus_kit::drawer::Drawer;
use locus_kit::kg_fact::KGFact;
use locus_kit::tunnel::Tunnel;

/// Pre-built per-drawer graph-centrality cache for one estate.
///
/// Holds the eigenvalue-centrality score for every live drawer, computed by
/// the governor's `graph_centrality_duty` on a cadence. Implements the GLK
/// `recall::GraphCache` consumption trait: the `matrixAware` / `unionBest`
/// recall path reads `graph_score(drawer_id)` per candidate drawer to populate
/// the `graph` score column. Drawers absent from the snapshot score 0.0, which
/// is correct (a drawer with no structural edges has no centrality).
///
/// Immutable after construction — the producer builds a fresh cache each
/// cadence and re-registers it, so a registered cache never mutates under a
/// concurrent recall read. Mirrors Swift `GraphCentralityCache`.
pub struct GraphCentralityCache {
    /// drawer_id → eigenvalue centrality. Built once at construction.
    scores: HashMap<String, f32>,
}

impl GraphCentralityCache {
    /// Wrap a per-drawer centrality snapshot.
    pub fn new(scores: HashMap<String, f32>) -> Self {
        Self { scores }
    }

    /// Number of drawers in the snapshot. Diagnostic accessor surfaced in the
    /// producer's tick log. Mirrors Swift `GraphCentralityCache.count`.
    pub fn count(&self) -> usize {
        self.scores.len()
    }
}

impl GraphCache for GraphCentralityCache {
    /// The centrality score for `drawer_id`, or 0.0 when the drawer is not in
    /// the snapshot. A pure map lookup — no estate traversal, honouring the
    /// candidate-frontier-lookup-only contract (spec §15). Mirrors Swift
    /// `GraphCentralityCache.graphScore(for:)`.
    fn graph_score(&self, drawer_id: &str) -> f32 {
        self.scores.get(drawer_id).copied().unwrap_or(0.0)
    }
}

/// The (node_ids, edges) pair the `neuron_kit::keystones` oracle consumes.
/// Mirrors Swift `GraphCentralityAdjacency.Graph`.
pub struct CentralityGraph {
    /// Live drawer IDs, sorted ascending (stable index space — keystones
    /// returns scores[i] for node_ids[i]).
    pub node_ids: Vec<String>,
    /// Undirected, unit-weight drawer-id edge pairs. keystones drops self-loops
    /// and absent-endpoint edges; we pre-filter to live nodes so the diagnostic
    /// counts are honest and the cross-port edge multiset is identical.
    pub edges: Vec<(String, String)>,
}

/// Build the canonical estate centrality graph — the EXACT shape and edge
/// multiset the Swift `GraphCentralityAdjacency.build` produces, so both ports
/// feed `keystones` the same graph and obtain identical centralities.
///
/// Node set: all non-tombstoned drawers, sorted ascending by id.
///
/// Edges (unit weight, the keystones model — NOT the topology lens's weighted
/// 1.0/0.3/0.2 split):
///   1. Tunnel edges — each non-tombstoned tunnel with both endpoints present
///      and both in the live node set contributes one pair.
///   2. KGFact edges — drawers sharing a KGFact `subject` are bonded. Facts are
///      grouped by subject; within each subject group the distinct live
///      source-drawer IDs are sorted ascending and all unordered pairs (i<j)
///      are emitted.
///
/// Determinism: tunnels are iterated in input order (a stable `filed_at`-ordered
/// estate read), subject groups (BTreeMap) and their members (BTreeSet) are
/// sorted, so the same estate state always yields the same edge sequence —
/// matching the Swift port byte-for-byte.
pub fn build_centrality_graph(
    drawers: &[Drawer],
    tunnels: &[Tunnel],
    facts: &[KGFact],
) -> CentralityGraph {
    // Live node set + sorted node ids.
    let live: BTreeSet<&str> = drawers
        .iter()
        .filter(|d| d.tombstoned_at.is_none())
        .map(|d| d.id.as_str())
        .collect();
    let node_ids: Vec<String> = live.iter().map(|s| s.to_string()).collect();

    let mut edges: Vec<(String, String)> = Vec::new();

    // 1. Tunnel edges — explicit drawer-to-drawer structural links.
    for tunnel in tunnels {
        if tunnel.tombstoned_at.is_some() {
            continue;
        }
        let (Some(a), Some(b)) = (&tunnel.source_drawer_id, &tunnel.target_drawer_id) else {
            continue;
        };
        if a == b || !live.contains(a.as_str()) || !live.contains(b.as_str()) {
            continue;
        }
        edges.push((a.clone(), b.clone()));
    }

    // 2. KGFact edges — drawers sharing a subject. Group, sort, pair.
    let mut by_subject: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for fact in facts {
        if live.contains(fact.source_drawer_id.as_str()) {
            by_subject
                .entry(fact.subject.as_str())
                .or_default()
                .insert(fact.source_drawer_id.as_str());
        }
    }
    for members in by_subject.values() {
        if members.len() < 2 {
            continue;
        }
        let ordered: Vec<&str> = members.iter().copied().collect();
        for i in 0..ordered.len() {
            for j in (i + 1)..ordered.len() {
                edges.push((ordered[i].to_string(), ordered[j].to_string()));
            }
        }
    }

    CentralityGraph { node_ids, edges }
}

/// Run the keystones oracle over the whole graph and reduce to a
/// drawer_id → f32 centrality map (the GraphCache payload). `keystones` over
/// ALL nodes (`top_k = node count`) gives every live drawer's centrality.
/// Empty node set ⇒ empty result ⇒ empty map (C-16). The `f64 → f32` narrowing
/// is the documented float boundary the cross-port conformance gate compares at.
///
/// `estate_id` and `now_epoch_secs` are threaded into SubstrateML so VizGraph
/// telemetry rows carry the correct estate tag and timestamp.
pub fn compute_centrality_scores(
    graph: &CentralityGraph,
    estate_id: &str,
    now_epoch_secs: f64,
) -> HashMap<String, f32> {
    let ranked = crate::keystones(&graph.node_ids, &graph.edges, graph.node_ids.len(), estate_id, now_epoch_secs);
    let mut scores = HashMap::with_capacity(ranked.len());
    for keystone in ranked {
        scores.insert(keystone.id, keystone.centrality as f32);
    }
    scores
}
