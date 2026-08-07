//! ConnectedRecall — the `recall_connected` recipe, Rust parity of the Swift
//! `ConnectedRecall.run(...)`: multi-hop retrieval by graph diffusion over
//! the estate's connection structure.
//!
//! WHY: similarity search measures local geometric distance to the QUESTION,
//! so it finds hop one of a multi-hop question and misses the answer turn
//! that shares no words with it. The deterministic fix is structural: seed a
//! random walk with restart (Monte Carlo personalized PageRank —
//! `substrate_ml::random_walks`, FNV-derived RNG seeds, bit-reproducible) at
//! the top scored hits and diffuse through the connection graph.
//!
//! THE GRAPH (Bob's ruling, 2026-08-06): tunnels are high-confidence edges
//! (obvious + human-validated); dream-produced Association rows are
//! PENDING-review candidates — "a tiny little bit less confident, like
//! 2–3%". Both are walked. The ~0.975 association discount is recorded, NOT
//! applied: the walk samples neighbors uniformly and a 2–3% edge preference
//! is below Monte Carlo visit-count resolution (see the Swift twin's header
//! for the full rationale).
//!
//! COST MODEL: this recipe IS the expensive path; callers escalate to it
//! for hard, infrequent bridge questions. Triggers stay caller-side.

use std::collections::{HashMap, HashSet};

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
use substrate_ml::random_walks::RandomWalks;
use substrate_types::fnv;
use substrate_types::row::RowId;
use uuid::Uuid;

use crate::error::{RecipeRunError, SubstrateError};

/// One connected-recall match. Twin of Swift `ConnectedMatch`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectedMatch {
    pub id: String,
    pub room: String,
    pub content: String,
    /// Which lane(s) surfaced this match: "anchor", "walk", or "both".
    pub source: String,
}

/// Defaults — twins of the Swift constants.
pub const CONNECTED_DEFAULT_SEEDS: usize = 3;
pub const CONNECTED_DEFAULT_STEPS: usize = 4_000;
pub const CONNECTED_DEFAULT_RESTART: f32 = 0.15;
const MAX_WALK_STEPS: usize = 50_000;

/// Runs connected recall. Deterministic for fixed inputs: walk RNG seeds
/// derive from the seed drawer ids (FNV-64), never a clock. Twin of Swift
/// `ConnectedRecall.run`.
#[allow(clippy::too_many_arguments)]
pub fn run_connected_recall(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    wing: &str,
    filter: Filter,
    limit: usize,
    now: i64,
) -> Result<Vec<ConnectedMatch>, RecipeRunError> {
    let safe_limit = limit.max(1);
    let pool = safe_limit.max(20);

    // 1. ANCHOR — the same high-recall scored grab PreciseRecall uses.
    //    Hydration .full: bodies ride along in this single scored recall
    //    (the Rust GLK exposes no per-id hydrate; same convention as the
    //    rust PreciseRecall).
    let frame = RecallFrame {
        filter_chain: vec![filter],
        hydration_level: HydrationLevel::Full,
        limit: Some(pool),
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: Some(safe_limit),
    };
    let request = GLKRecallRequest {
        frame,
        mode: GLKRecallMode::UnionBest,
        scoring: GLKRecallScoring::Raw,
        limit: pool,
        fallback: RecallFallbackPolicy::AllowDegraded,
        query_text: Some(query.to_string()),
        trace_limit: Some(safe_limit),
        origin: genius_locus_kit::recall::RecallOrigin::Internal,
        recall_shape: None,
    };
    let anchor = coord
        .recall_scored(handle, request, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    // id → (content, parent_node_id) for anchor hits (bodies pre-fetched).
    let mut anchor_ids: Vec<String> = Vec::new();
    let mut body_by_id: HashMap<String, (String, String)> = HashMap::new();
    for hit in &anchor.hits {
        if let Some(d) = &hit.drawer {
            anchor_ids.push(d.id.clone());
            body_by_id.insert(d.id.clone(), (d.content.clone(), d.parent_node_id.clone()));
        }
    }

    // 2. GRAPH — tunnels (validated, wing-scoped read) ∪ associations
    //    (pending review, estate-wide), both directions, drawer-endpoint
    //    edges only. Twin of the Swift addEdge closure.
    let mut adjacency: HashMap<RowId, Vec<RowId>> = HashMap::new();
    let add_edge =
        |a: &Option<String>, b: &Option<String>, adj: &mut HashMap<RowId, Vec<RowId>>| {
            let (Some(a_str), Some(b_str)) = (a, b) else { return };
            let (Ok(a_id), Ok(b_id)) = (Uuid::parse_str(a_str), Uuid::parse_str(b_str)) else {
                return;
            };
            adj.entry(RowId(a_id.as_u128())).or_default().push(RowId(b_id.as_u128()));
            adj.entry(RowId(b_id.as_u128())).or_default().push(RowId(a_id.as_u128()));
        };
    if !wing.is_empty() {
        let tunnels = coord
            .recall_tunnels(handle, wing)
            .map_err(|e| SubstrateError::new("recall_tunnels", format!("{e:?}")))?;
        for t in &tunnels {
            add_edge(&t.source_drawer_id, &t.target_drawer_id, &mut adjacency);
        }
    }
    let associations = coord
        .recall_associations(handle)
        .map_err(|e| SubstrateError::new("recall_associations", format!("{e:?}")))?;
    for a in &associations {
        add_edge(&a.source_drawer_id, &a.target_drawer_id, &mut adjacency);
    }

    // 3. DIFFUSION — one walk per anchor seed, visit counts summed. A seed
    //    with no edges contributes nothing; a structureless estate degrades
    //    to the plain anchor ranking, never below it.
    let mut visit_totals: HashMap<RowId, u64> = HashMap::new();
    for seed_id in anchor_ids.iter().take(CONNECTED_DEFAULT_SEEDS) {
        let Ok(seed_uuid) = Uuid::parse_str(seed_id) else { continue };
        let seed_row = RowId(seed_uuid.as_u128());
        if !adjacency.contains_key(&seed_row) {
            continue;
        }
        let visits = RandomWalks::walk_with_restart(
            seed_row,
            CONNECTED_DEFAULT_STEPS.min(MAX_WALK_STEPS),
            CONNECTED_DEFAULT_RESTART,
            fnv::hash64(seed_id),
            &adjacency,
        );
        for (row, count) in visits {
            *visit_totals.entry(row).or_insert(0) += count;
        }
    }
    // Rank walk hits by summed visits, deterministic tie-break by id.
    let mut walk_ranked: Vec<(RowId, u64)> = visit_totals.into_iter().collect();
    walk_ranked.sort_by(|a, b| b.1.cmp(&a.1).then(Uuid::from_u128(a.0.0).to_string().cmp(&Uuid::from_u128(b.0.0).to_string())));
    let walk_ids: Vec<String> = walk_ranked.iter().map(|(r, _)| Uuid::from_u128(r.0).to_string().to_uppercase()).collect();

    // 4. FUSION — RRF (k = 60) over the two ranked lists; both lanes are
    //    relevance-bearing (scored similarity / structural reachability
    //    from those anchors), so equal weights are the honest fusion.
    let mut score: HashMap<String, f64> = HashMap::new();
    for (rank, id) in anchor_ids.iter().enumerate() {
        *score.entry(id.clone()).or_insert(0.0) += 1.0 / (60.0 + rank as f64 + 1.0);
    }
    for (rank, id) in walk_ids.iter().enumerate() {
        *score.entry(id.clone()).or_insert(0.0) += 1.0 / (60.0 + rank as f64 + 1.0);
    }
    let mut fused: Vec<(String, f64)> = score.into_iter().collect();
    fused.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then(a.0.cmp(&b.0)));
    let fused_ids: Vec<String> = fused.into_iter().take(safe_limit).map(|(id, _)| id).collect();

    // 5. HYDRATE walk-only survivors through the normal RecallFrame boundary.
    //    Graph edges can outlive a drawer's visibility, so a raw corpus lookup
    //    here would let a stale edge disclose a tombstoned or sensitive row.
    //    Anchor rows already carry bodies from the gated scored recall.
    let walk_set: HashSet<&String> = walk_ids.iter().collect();
    let anchor_set: HashSet<&String> = anchor_ids.iter().collect();
    let needs_bodies: Vec<&String> = fused_ids
        .iter()
        .filter(|id| !body_by_id.contains_key(*id))
        .collect();
    if !needs_bodies.is_empty() {
        if let Ok(estate) = coord.estate_for(handle) {
            let ids: Vec<String> = needs_bodies.into_iter().cloned().collect();
            let mut frame = RecallFrame::new(vec![]);
            frame.hydration_level = HydrationLevel::Full;
            if let Ok(found) = estate.get_drawers_matching_frame(&ids, &frame) {
                for d in found.admissible {
                    body_by_id.insert(d.id.clone(), (d.content.clone(), d.parent_node_id.clone()));
                }
            }
        }
    }

    Ok(fused_ids
        .into_iter()
        .map(|id| {
            let in_anchor = anchor_set.contains(&id);
            let in_walk = walk_set.contains(&id);
            let source = if in_anchor && in_walk {
                "both"
            } else if in_anchor {
                "anchor"
            } else {
                "walk"
            };
            let (content, node) = body_by_id.get(&id).cloned().unwrap_or_default();
            ConnectedMatch {
                id,
                // The aria layer resolves node ids to display room names; the
                // recipe carries the raw parent node id (same convention as
                // the rust PreciseMatch room field).
                room: node,
                content,
                source: source.to_string(),
            }
        })
        .collect())
}
