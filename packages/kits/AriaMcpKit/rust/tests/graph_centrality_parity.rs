// graph_centrality_parity.rs
//
// Conformance + behaviour coverage for the graph-centrality PRODUCER — the Rust
// mirror of Swift `GraphCentralityProducerTests.swift`. The producer is the
// cadence wrapper (governor duty `graph_centrality_duty`) that takes the recall
// `graph` score column from DARK to LIVE: nothing previously computed per-drawer
// eigenvalue centrality and registered the GraphCache the matrixAware/unionBest
// recall reads.
//
// Proofs (mirroring the Swift suite case-for-case):
//   - faithful-wrapper: build_centrality_graph + compute_centrality_scores equal
//     a DIRECT neuron_kit::keystones call on the same (node_ids, edges) graph;
//   - structure sanity: the hub of a star outranks its spokes;
//   - kg_facts edges: drawers sharing a subject are bonded with no tunnel;
//   - C-16 totality: an empty estate yields an empty cache, edgeless scores
//     uniformly;
//   - cadence: the producer fires on the first tick and respects its interval;
//   - end-to-end: after a tick, a unionBest+matrixAware recall reads a non-zero
//     `graph` column for the hub (dark→live, proving registration on the coord).

use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use neuron_kit::autonomic_governor::AutonomicGovernor;
use aria_mcp::estate_registry::EstateRegistry;
use neuron_kit::graph_centrality::{
    build_centrality_graph, compute_centrality_scores, GraphCentralityCache,
};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, GraphCache,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::{CaptureFrame, TunnelCaptureFrame};

const NOW: i64 = 1_700_000_000;

// ── Harness ────────────────────────────────────────────────────────────────────

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "centrality",
        LatticeAnchor::udc("0"),
        "centrality-tests",
        "test-embed-v1",
    )
}

/// Capture a drawer through the coordinator and return its generated id.
fn capture(registry: &EstateRegistry, content: &str) -> String {
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, cap_frame(content), NOW)
        .expect("capture")
        .id
}

/// Create a drawer-to-drawer tunnel between two REAL captured drawer ids. The
/// producer filters edges to live drawers, so endpoints must be real ids.
fn add_tunnel(registry: &EstateRegistry, src: &str, tgt: &str) {
    let mut frame =
        TunnelCaptureFrame::new("centrality", "r", "centrality", "r", "relates", "centrality-tests");
    frame.source_drawer_id = Some(src.to_string());
    frame.target_drawer_id = Some(tgt.to_string());
    let coord = registry.coord.lock().unwrap();
    let estate = coord.estate_for(&registry.default.handle).expect("estate");
    estate.capture_tunnel(frame, NOW).expect("capture_tunnel");
}

/// Build a star: one hub tunnelled to N spokes. Returns (hub_id, spoke_ids).
fn build_star(registry: &EstateRegistry, spoke_count: usize) -> (String, Vec<String>) {
    let hub = capture(registry, "hub memory");
    let mut spokes = Vec::new();
    for i in 0..spoke_count {
        let s = capture(registry, &format!("spoke {i}"));
        add_tunnel(registry, &hub, &s);
        spokes.push(s);
    }
    (hub, spokes)
}

/// The cache the producer WOULD register, built from the same reads + adjacency
/// + oracle the duty uses. Used by the pure proofs.
fn produced_cache(registry: &EstateRegistry) -> (GraphCentralityCache, Vec<String>) {
    let coord = registry.coord.lock().unwrap();
    let h = &registry.default.handle;
    // Hint drawers (AI_Charter_Hint room) are normal drawers — included in the
    // centrality graph like any other drawer. No exclusion filter.
    let drawers: Vec<_> = coord
        .all_drawers(h)
        .expect("all_drawers")
        .into_iter()
        .collect();
    let tunnels = coord.all_tunnels(h).expect("all_tunnels");
    let facts = coord.recall_kg_facts(h).expect("recall_kg_facts");
    let graph = build_centrality_graph(&drawers, &tunnels, &facts);
    let node_ids = graph.node_ids.clone();
    let scores = compute_centrality_scores(&graph);
    (GraphCentralityCache::new(scores), node_ids)
}

// ── Faithful wrapper (the conformance proof) ────────────────────────────────────

/// The producer's cache MUST equal a direct neuron_kit::keystones call on the
/// producer's own (node_ids, edges) graph — bit-identical f32. Proves the
/// producer is a faithful cadence wrapper of the oracle and reinvents no math
/// (I-17). Also the cross-port contract: the Swift producer computes the same
/// scores from the same graph.
#[test]
fn producer_equals_direct_keystones() {
    let registry = EstateRegistry::new_inmemory();
    let (hub, _) = build_star(&registry, 4);

    let (cache, node_ids) = produced_cache(&registry);

    // Direct oracle call on the producer's graph — all drawers including hints.
    // No hint-drawer filter: hint drawers are normal graph nodes.
    let coord = registry.coord.lock().unwrap();
    let h = &registry.default.handle;
    let drawers: Vec<_> = coord
        .all_drawers(h)
        .unwrap()
        .into_iter()
        .collect();
    let tunnels = coord.all_tunnels(h).unwrap();
    let facts = coord.recall_kg_facts(h).unwrap();
    let graph = build_centrality_graph(&drawers, &tunnels, &facts);
    let ranked = neuron_kit::keystones(&graph.node_ids, &graph.edges, graph.node_ids.len());
    let mut expected = std::collections::HashMap::new();
    for k in ranked {
        expected.insert(k.id, k.centrality as f32);
    }

    for id in &node_ids {
        let exp = expected.get(id).copied().unwrap_or(0.0);
        assert_eq!(
            cache.graph_score(id), exp,
            "cached score for {id} must equal the direct keystones score"
        );
    }
    assert!(cache.graph_score(&hub) > 0.0, "hub must carry positive centrality");
}

// ── Structure sanity ────────────────────────────────────────────────────────────

/// The hub of a star outranks every spoke — the eigenvalue-centrality behaviour
/// the keystones oracle guarantees, surfaced through the producer.
#[test]
fn hub_outscores_spokes() {
    let registry = EstateRegistry::new_inmemory();
    let (hub, spokes) = build_star(&registry, 4);
    let (cache, _) = produced_cache(&registry);
    let hub_score = cache.graph_score(&hub);
    for s in &spokes {
        assert!(
            hub_score > cache.graph_score(s),
            "hub centrality must exceed spoke {s}"
        );
    }
}

// ── KGFact edges contribute ─────────────────────────────────────────────────────

/// Two drawers sharing a KGFact subject are bonded by the producer even with no
/// tunnel between them — the kg_facts half of the adjacency is live. Eigenvalue
/// centrality normalizes the eigenvector, so the isolated node carries a tiny
/// residual rather than exact 0 — the meaningful claim is bonded > isolated.
#[test]
fn kg_fact_subject_bond_contributes() {
    let registry = EstateRegistry::new_inmemory();
    let a = capture(&registry, "fact source a");
    let b = capture(&registry, "fact source b");
    let c = capture(&registry, "fact source c");
    {
        let coord = registry.coord.lock().unwrap();
        let h = &registry.default.handle;
        coord.add_kg_fact(h, "S", "p", "o1", &a, NOW).expect("fact a");
        coord.add_kg_fact(h, "S", "p", "o2", &b, NOW + 1).expect("fact b");
    }
    let (cache, _) = produced_cache(&registry);
    assert!(
        cache.graph_score(&a) > cache.graph_score(&c),
        "subject-bonded drawer a must outrank the isolated drawer c"
    );
    assert!(
        cache.graph_score(&b) > cache.graph_score(&c),
        "subject-bonded drawer b must outrank the isolated drawer c"
    );
}

// ── C-16 totality ───────────────────────────────────────────────────────────────

/// An estate with no drawers yields an empty cache; every score is 0.0.
#[test]
fn empty_estate_registers_zero_cache() {
    // _bare: a genuinely empty estate (no seeded AI_Charter_Hint wing drawers),
    // so the cache is empty and count() == 0.
    let registry = EstateRegistry::new_inmemory_bare();
    let (cache, _) = produced_cache(&registry);
    assert_eq!(cache.graph_score("nonexistent"), 0.0);
    assert_eq!(cache.count(), 0);
}

/// Captured drawers with NO edges score UNIFORMLY: eigenvalue centrality of an
/// edgeless graph gives every node the same normalized value.
#[test]
fn edgeless_estate_scores_uniformly() {
    let registry = EstateRegistry::new_inmemory();
    let d1 = capture(&registry, "lonely drawer one");
    let d2 = capture(&registry, "lonely drawer two");
    let (cache, _) = produced_cache(&registry);
    assert_eq!(
        cache.graph_score(&d1), cache.graph_score(&d2),
        "edgeless nodes must score uniformly (no structural prominence)"
    );
}

// ── Cadence ─────────────────────────────────────────────────────────────────────

/// The producer fires on the first tick (last-fired marker is None).
#[test]
fn fires_on_first_tick() {
    let registry = EstateRegistry::new_inmemory();
    let mut governor = AutonomicGovernor::new(
        Arc::clone(&registry.coord),
        registry.default.handle,
        Arc::clone(&registry.default.store),
    );
    governor.set_graph_centrality_cadence_ms(0); // every tick
    let report = governor.tick(UNIX_EPOCH);
    assert!(report.graph_centrality_fired, "must fire on the first tick");
}

/// The producer respects its cadence: first fires, before-interval skips,
/// at-boundary fires. Default cadence is 600 s (10 min).
#[test]
fn respects_cadence() {
    let registry = EstateRegistry::new_inmemory();
    let mut governor = AutonomicGovernor::new(
        Arc::clone(&registry.coord),
        registry.default.handle,
        Arc::clone(&registry.default.store),
    );
    let first = governor.tick(UNIX_EPOCH);
    assert!(first.graph_centrality_fired, "first tick fires");
    let early = governor.tick(UNIX_EPOCH + Duration::from_secs(1));
    assert!(!early.graph_centrality_fired, "1 s < 600 s → skip");
    let due = governor.tick(UNIX_EPOCH + Duration::from_secs(600));
    assert!(due.graph_centrality_fired, "600 s elapsed → fires");
}

// ── End-to-end: dark → live (proves registration) ───────────────────────────────

/// After the producer tick scans a star estate, a unionBest+matrixAware recall
/// reads a NON-ZERO `graph` column for the hub drawer. Closes the dark-column
/// gap and proves the duty REGISTERED the cache on the coordinator (the recall
/// path reads `graph_cache(handle)`).
#[test]
fn recall_reads_live_graph_column() {
    let registry = EstateRegistry::new_inmemory();
    let (hub, _) = build_star(&registry, 4);

    // Drive the producer via a governor tick (cadence 0 → fires now).
    let mut governor = AutonomicGovernor::new(
        Arc::clone(&registry.coord),
        registry.default.handle,
        Arc::clone(&registry.default.store),
    );
    governor.set_graph_centrality_cadence_ms(0);
    let report = governor.tick(UNIX_EPOCH);
    assert!(report.graph_centrality_fired, "producer must fire");

    // The producer registered the cache on the shared coordinator — recall it.
    let coord = registry.coord.lock().unwrap();
    let h = &registry.default.handle;
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_limit(50);
    let result = coord.recall_scored(h, req, NOW + 10).expect("recall");

    let hub_hit = result
        .hits
        .iter()
        .find(|hit| hit.id == hub)
        .expect("the hub drawer must be recalled");
    assert!(
        hub_hit.score.graph > 0.0,
        "the graph column must be live (non-zero) for the hub after the producer ran"
    );
}
