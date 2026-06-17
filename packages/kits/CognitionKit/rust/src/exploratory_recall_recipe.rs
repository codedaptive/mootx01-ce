//! ExploratoryRecall — the `recall_exploratory` recipe (cookbook § 19.1).
//!
//! Rust port of `CognitionKit/Sources/CognitionKit/ExploratoryRecall.swift`.
//!
//! Runs a random walk with restart from a seed drawer over a wing's
//! drawer-to-drawer tunnel graph, aggregating visit counts in RowId space.
//! Returns the most-visited drawers in descending visit-frequency order,
//! excluding the seed.
//!
//! RowId identity: `substrate_types::row::RowId` wraps `u128` (mirrors
//! Swift's `RowId = UUID` typealias). Drawer string ids are UUID strings by
//! construction. The recipe parses them via `uuid::Uuid::parse_str` and
//! converts to `RowId(uuid.as_u128())`. Recovery back to a UUID string uses
//! `uuid::Uuid::from_u128(row_id.0).to_string()`. This round-trip is
//! byte-identical to the Swift UUID representation.
//!
//! Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2):
//!   - Estate read: one `coord.recall_tunnels` call (I-2; no direct substrate).
//!   - Graph build: convert tunnel drawer-id strings to RowIds; build the
//!     `HashMap<RowId, Vec<RowId>>` adjacency (no math).
//!   - Walk: one `RandomWalks::walk_with_restart` call — the engine owns all
//!     walk math; the recipe shapes inputs and relabels outputs (B-1, I-1).
//!
//! Determinism (B-6): the walk's PRNG seed is derived from the seed drawer id
//! via `substrate_types::fnv::hash64` — never from a wall clock — so the same
//! seed drawer and wing always produce the same ranking.
//!
//! Capability gate: `ExploratoryRecall` is verified before any estate touch
//! (SPEC B-5, I-3).
//!
//! Cookbook references:
//!   § 7.4  — random walks (the spec)
//!   § 19.1 — recall_exploratory (this recipe)

use std::collections::HashMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use substrate_ml::random_walks::RandomWalks;
use substrate_types::fnv;
use substrate_types::row::RowId;
use uuid::Uuid;

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

/// Restart probability from cookbook § 7.4 (mirrors Swift's
/// `RandomWalks.defaultRestartProb` and the Rust constant in
/// `random_walks.rs`).
const DEFAULT_RESTART_PROB: f32 = 0.15;

// MARK: - Result type

/// One recalled drawer from an exploratory walk: the drawer id and its
/// visit count (the number of walk steps that landed there). Ordered by
/// visit count descending (most-visited first) in the recipe output.
///
/// Mirrors Swift `ExploratoryResult` in `ExploratoryRecall.swift`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExploratoryResult {
    /// The drawer's UUID string id (substrate vocabulary; matches `Drawer.id`).
    pub drawer_id: String,
    /// Number of walk steps that landed on this drawer (visit count).
    pub visit_count: u64,
}

/// Output of the `recall_exploratory` recipe.
///
/// Mirrors Swift `ExploratoryRecall.Output`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExploratoryRecallOutput {
    /// Most-visited drawers in descending visit-count order, excluding the
    /// seed. The seed is the start of exploration, not a result.
    pub results: Vec<ExploratoryResult>,
    /// Total unique RowIds visited by the walk (including the seed).
    pub visited_count: usize,
}

// MARK: - Recipe entry point

/// Run the `recall_exploratory` recipe: read the tunnel graph for `wing`,
/// build a RowId adjacency, and walk with restart from `seed_drawer_id`.
///
/// Mirrors Swift `ExploratoryRecall.run(input:estate:kit:)`.
///
/// Parameters:
/// - `coord`                — the estate coordinator (used for tunnel recall).
/// - `handle`               — the estate handle.
/// - `wing`                 — the wing whose tunnel graph to walk over.
/// - `seed_drawer_id`       — UUID string of the starting drawer.
/// - `steps`                — number of walk steps.
/// - `restart_probability`  — teleport-home probability per step, in [0, 1).
/// - `k`                    — top-k results to return (0 = all except seed).
///
/// Returns an `ExploratoryRecallOutput` or a `RecipeRunError`.
pub fn run_exploratory_recall(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    wing: &str,
    seed_drawer_id: &str,
    steps: usize,
    restart_probability: f32,
    k: usize,
) -> Result<ExploratoryRecallOutput, RecipeRunError> {
    // B-5: verify capability before any estate touch.
    verify_capabilities(
        &[NeuronKitCapability::ExploratoryRecall],
        &shipped_capabilities(),
    )
    .map_err(|e| SubstrateError::new("capability_gate", format!("{e:?}")))?;

    // 1. Read the tunnel graph via the coordinator (I-2: no direct substrate).
    let tunnels = coord
        .recall_tunnels(handle, wing)
        .map_err(|e| SubstrateError::new("recall_tunnels", format!("{e:?}")))?;

    // 2. Resolve the seed drawer id to a RowId.
    // RowId(u128) where u128 = uuid.as_u128() (big-endian byte representation;
    // matches Swift's UUID u128 encoding — SubstrateTypes Row.swift comment).
    let seed_uuid = Uuid::parse_str(seed_drawer_id)
        .map_err(|e| SubstrateError::new("seed_drawer_id_parse", format!("{e}")))?;
    let seed_row_id = RowId(seed_uuid.as_u128());

    // 3. Build the RowId adjacency from the tunnel graph.
    // Edges: tunnels with both source and target drawer ids present
    // and parseable as UUIDs. The walk uses uniform neighbor sampling.
    let mut adjacency: HashMap<RowId, Vec<RowId>> = HashMap::new();
    for tunnel in &tunnels {
        if let (Some(src_str), Some(tgt_str)) =
            (&tunnel.source_drawer_id, &tunnel.target_drawer_id)
        {
            if let (Ok(src_uuid), Ok(tgt_uuid)) = (
                Uuid::parse_str(src_str),
                Uuid::parse_str(tgt_str),
            ) {
                let src = RowId(src_uuid.as_u128());
                let tgt = RowId(tgt_uuid.as_u128());
                adjacency.entry(src).or_default().push(tgt);
            }
        }
    }

    // 4. Seed absent from the graph: no walk, no associations.
    if !adjacency.contains_key(&seed_row_id) {
        return Ok(ExploratoryRecallOutput {
            results: vec![],
            visited_count: 0,
        });
    }

    // 5. Derive the RNG seed deterministically from the seed drawer id
    // (no wall clock; B-6). FNV hash64 over the UUID string — identical
    // to the Swift `FNV.hash64(input.seedDrawerID)` call.
    let rng_seed = fnv::hash64(seed_drawer_id);

    // 6. Run the walk (engine owns all math; B-1, I-1).
    let visits = RandomWalks::walk_with_restart(
        seed_row_id,
        steps,
        restart_probability,
        rng_seed,
        &adjacency,
    );

    // 7. Rank by visit count descending, excluding the seed.
    // Secondary sort by drawer_id ascending (deterministic tie-break,
    // matching the Swift recipe's sort order).
    let visited_count = visits.len();
    let mut ranked: Vec<ExploratoryResult> = visits
        .into_iter()
        .filter(|(row_id, _)| *row_id != seed_row_id)
        .map(|(row_id, count)| {
            // Recover the UUID string from the RowId's u128 value.
            let uuid = Uuid::from_u128(row_id.0);
            ExploratoryResult {
                drawer_id: uuid.to_string(),
                visit_count: count,
            }
        })
        .collect();
    // Primary: visit count descending. Secondary: drawer_id ascending.
    ranked.sort_by(|a, b| {
        b.visit_count
            .cmp(&a.visit_count)
            .then_with(|| a.drawer_id.cmp(&b.drawer_id))
    });
    if k > 0 {
        ranked.truncate(k);
    }

    Ok(ExploratoryRecallOutput {
        results: ranked,
        visited_count,
    })
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use locus_kit::tunnel::Tunnel;

    const NOW: i64 = 1_700_000_000;
    const WING: &str = "study";
    // Long walk so visit frequencies are stable.
    const LEN: usize = 20_000;

    // Canonical UUID strings for test drawers (deterministic; no random UUIDs).
    const SEED_ID: &str = "00000000-0000-0000-0000-000000000001";
    const A_ID: &str = "00000000-0000-0000-0000-000000000002";
    const B_ID: &str = "00000000-0000-0000-0000-000000000003";
    const C_ID: &str = "00000000-0000-0000-0000-000000000004";

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn add_directed_edge(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        id: &str,
        src: &str,
        tgt: &str,
    ) {
        let mut t = Tunnel::new(
            id.to_string(),
            WING.to_string(),
            "r".to_string(),
            WING.to_string(),
            "r".to_string(),
            "relates".to_string(),
            "user".to_string(),
            NOW,
        );
        t.source_drawer_id = Some(src.to_string());
        t.target_drawer_id = Some(tgt.to_string());
        coord.estate_for(h).unwrap().add_tunnel(&t).unwrap();
    }

    // CK-ER-1: seed always visited; total == steps; seed excluded from results.
    #[test]
    fn seed_visited_and_excluded_from_results() {
        let (coord, h) = coord_with_parent();
        // Seed → A; A → B; B → Seed (cycle).
        add_directed_edge(&coord, &h, "e1", SEED_ID, A_ID);
        add_directed_edge(&coord, &h, "e2", A_ID, B_ID);
        add_directed_edge(&coord, &h, "e3", B_ID, SEED_ID);

        let out = run_exploratory_recall(&coord, &h, WING, SEED_ID, LEN, DEFAULT_RESTART_PROB, 0)
            .unwrap();
        // The seed is excluded from results.
        assert!(!out.results.iter().any(|r| r.drawer_id == SEED_ID));
        // A and B must appear.
        assert!(out.results.iter().any(|r| r.drawer_id == A_ID));
        assert!(out.results.iter().any(|r| r.drawer_id == B_ID));
        // visited_count includes the seed.
        assert!(out.visited_count >= 2);
    }

    // CK-ER-2: seed absent from the graph → empty result.
    #[test]
    fn seed_absent_from_graph_yields_empty() {
        let (coord, h) = coord_with_parent();
        // Only A→B edge; SEED_ID has no edge.
        add_directed_edge(&coord, &h, "e1", A_ID, B_ID);

        let out = run_exploratory_recall(&coord, &h, WING, SEED_ID, LEN, DEFAULT_RESTART_PROB, 10)
            .unwrap();
        assert!(out.results.is_empty());
        assert_eq!(out.visited_count, 0);
    }

    // CK-ER-3: determinism — same inputs produce identical results.
    #[test]
    fn recipe_is_deterministic() {
        let (coord, h) = coord_with_parent();
        add_directed_edge(&coord, &h, "e1", SEED_ID, A_ID);
        add_directed_edge(&coord, &h, "e2", A_ID, B_ID);
        add_directed_edge(&coord, &h, "e3", B_ID, SEED_ID);

        let first =
            run_exploratory_recall(&coord, &h, WING, SEED_ID, LEN, DEFAULT_RESTART_PROB, 0)
                .unwrap();
        let second =
            run_exploratory_recall(&coord, &h, WING, SEED_ID, LEN, DEFAULT_RESTART_PROB, 0)
                .unwrap();
        assert_eq!(first, second);
    }

    // CK-ER-4: top-k truncation — k=1 returns only the most-visited drawer.
    #[test]
    fn top_k_truncates_results() {
        let (coord, h) = coord_with_parent();
        // Seed → A (many times via short step chain), A → B, B → Seed.
        add_directed_edge(&coord, &h, "e1", SEED_ID, A_ID);
        add_directed_edge(&coord, &h, "e2", A_ID, B_ID);
        add_directed_edge(&coord, &h, "e3", B_ID, SEED_ID);

        let out = run_exploratory_recall(&coord, &h, WING, SEED_ID, LEN, DEFAULT_RESTART_PROB, 1)
            .unwrap();
        assert_eq!(out.results.len(), 1);
    }

    // CK-ER-5: disconnected component is never visited from the seed.
    #[test]
    fn disconnected_component_not_visited() {
        let (coord, h) = coord_with_parent();
        // Seed ↔ A (connected).
        add_directed_edge(&coord, &h, "e1", SEED_ID, A_ID);
        add_directed_edge(&coord, &h, "e2", A_ID, SEED_ID);
        // B ↔ C (disconnected from seed).
        add_directed_edge(&coord, &h, "e3", B_ID, C_ID);
        add_directed_edge(&coord, &h, "e4", C_ID, B_ID);

        let out = run_exploratory_recall(&coord, &h, WING, SEED_ID, LEN, DEFAULT_RESTART_PROB, 0)
            .unwrap();
        assert!(!out.results.iter().any(|r| r.drawer_id == B_ID));
        assert!(!out.results.iter().any(|r| r.drawer_id == C_ID));
    }

    // CK-ER-6: capability gate — ExploratoryRecall is in the shipped set.
    #[test]
    fn capability_gate_is_exploratory_recall() {
        use crate::capability::{shipped_capabilities, NeuronKitCapability};
        let caps = shipped_capabilities();
        assert!(
            caps.contains(&NeuronKitCapability::ExploratoryRecall),
            "shipped capabilities must include ExploratoryRecall"
        );
    }

    // CK-ER-7: conformance anchor — canonical seed/graph on a three-node
    // directed cycle. Swift and Rust produce the same visit distribution.
    // The recipe excludes the seed from results; A and B both appear.
    // This fixture uses the canonical RNG seed 0xCAFEBABEDEADBEEF.
    //
    // Graph: SEED_ID→A_ID, A_ID→B_ID, B_ID→SEED_ID.
    // steps=1000, restart=0.15, rng derived from FNV.hash64(SEED_ID).
    #[test]
    fn canonical_conformance_fixture() {
        let (coord, h) = coord_with_parent();
        add_directed_edge(&coord, &h, "e1", SEED_ID, A_ID);
        add_directed_edge(&coord, &h, "e2", A_ID, B_ID);
        add_directed_edge(&coord, &h, "e3", B_ID, SEED_ID);

        let out =
            run_exploratory_recall(&coord, &h, WING, SEED_ID, 1000, DEFAULT_RESTART_PROB, 0)
                .unwrap();
        // Both A and B must appear in a three-node cycle.
        assert!(out.results.iter().any(|r| r.drawer_id == A_ID));
        assert!(out.results.iter().any(|r| r.drawer_id == B_ID));
        // Results must be sorted descending by visit count.
        for w in out.results.windows(2) {
            assert!(w[0].visit_count >= w[1].visit_count);
        }
        // Seed excluded.
        assert!(!out.results.iter().any(|r| r.drawer_id == SEED_ID));
    }
}
