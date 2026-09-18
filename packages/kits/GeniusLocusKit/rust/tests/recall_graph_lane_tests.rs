// recall_graph_lane_tests.rs
//
// Rust attribution gate for the graph/tunnel-expansion lane (step 4.35 in
// recall_scored_multi_lane). Parity peer of Swift RecallGraphLaneTests.
//
// Tests:
//  1. graph_expansion_candidate_carries_locus_graph — a drawer reachable only
//     via a tunnel from a locus hit appears in unionBest results with
//     RecallEvidencePath::LocusGraph in its sources.
//
//  2. direct_locus_hit_does_not_carry_locus_graph — a drawer that is a direct
//     locus hit with no tunnels pointing to it carries LocusBitmap but NOT
//     LocusGraph.
//
//  3. drawer_that_is_both_locus_hit_and_tunnel_target_carries_both_bits — when
//     a drawer is a direct locus hit AND a tunnel target, it carries both
//     LocusBitmap and LocusGraph (source map OR-union in recall_scored_multi_lane).

use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath,
    RecallFallbackPolicy, RecallOrigin,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::{CaptureFrame, TunnelCaptureFrame};

const NOW: i64 = 1_700_000_100;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one(suffix: &str) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(&format!("owner-graph-lane-{suffix}")), 0, 100)
        .expect("open estate");
    (coord, handle)
}

fn capture_frame(content: &str, room: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("000"),
        "graph-lane-tests",
        "test-model-v1",
    )
}

/// Tunnel frame wiring source_drawer_id → target_drawer_id directly.
fn tunnel_frame_with_ids(
    src_wing: &str,
    tgt_wing: &str,
    label: &str,
    source_drawer_id: &str,
    target_drawer_id: &str,
) -> TunnelCaptureFrame {
    let mut f = TunnelCaptureFrame::new(src_wing, src_wing, tgt_wing, tgt_wing, label, "graph-lane-tests");
    f.source_drawer_id = Some(source_drawer_id.to_string());
    f.target_drawer_id = Some(target_drawer_id.to_string());
    f
}

/// Recall frame matching all currently-believed rows.
fn active_frame() -> RecallFrame {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Structured;
    frame
}

/// UnionBest + MatrixAware recall request with no query text.
fn union_best_request(limit: usize) -> GLKRecallRequest {
    GLKRecallRequest::new(
        active_frame(),
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        limit,
        RecallFallbackPolicy::AllowDegraded,
        RecallOrigin::Internal,
    )
}

// ---------------------------------------------------------------------------
// 1. Graph-expansion candidate carries LocusGraph
// ---------------------------------------------------------------------------

/// A drawer that is reachable via a tunnel from a locus hit must have
/// `RecallEvidencePath::LocusGraph` in its `sources` after unionBest recall.
///
/// Both drawerA and drawerB are currently-believed (so both appear in the
/// locus lane). A tunnel from A → B is captured. After recall, drawerB must
/// carry LocusGraph (set by the graph expansion step) in addition to
/// LocusBitmap (set by the locus lane).
#[test]
fn graph_expansion_candidate_carries_locus_graph() {
    let (coord, h) = open_one("1");
    let estate = coord.estate_for(&h).expect("estate");

    // drawerA: direct locus hit.
    let drawer_a = coord
        .capture(&h, capture_frame("locus-hit-A", "wing-A"), NOW)
        .expect("capture A");

    // drawerB: also a direct locus hit AND will be a tunnel target.
    let drawer_b = coord
        .capture(&h, capture_frame("tunnel-neighbor-B", "wing-B"), NOW + 1)
        .expect("capture B");

    // Tunnel from drawerA → drawerB via source_drawer_id / target_drawer_id.
    estate
        .capture_tunnel(
            tunnel_frame_with_ids("wing-A", "wing-B", "graph-lane-link", &drawer_a.id, &drawer_b.id),
            NOW + 2,
        )
        .expect("capture tunnel");

    let result = coord
        .recall_scored(&h, union_best_request(20), NOW + 3)
        .expect("recall");

    let hit_b = result.hits.iter().find(|h| h.id == drawer_b.id);
    assert!(hit_b.is_some(), "drawerB (tunnel target) must appear in results");
    let sources = &hit_b.unwrap().sources;
    assert!(
        sources.contains(&RecallEvidencePath::LocusGraph),
        "drawerB must have LocusGraph in sources (got {sources:?})"
    );
}

// ---------------------------------------------------------------------------
// 2. Direct locus hit with no tunnels does NOT carry LocusGraph
// ---------------------------------------------------------------------------

/// A drawer that is a pure locus-bitmap hit with no tunnel pointing to it
/// must carry LocusBitmap but NOT LocusGraph.
#[test]
fn direct_locus_hit_does_not_carry_locus_graph() {
    let (coord, h) = open_one("2");

    let drawer = coord
        .capture(&h, capture_frame("pure-locus-hit", "room-1"), NOW)
        .expect("capture");

    let result = coord
        .recall_scored(&h, union_best_request(10), NOW + 1)
        .expect("recall");

    let hit = result.hits.iter().find(|h| h.id == drawer.id);
    assert!(hit.is_some(), "drawer must appear in results");
    let sources = &hit.unwrap().sources;
    assert!(
        sources.contains(&RecallEvidencePath::LocusBitmap),
        "pure-locus drawer must have LocusBitmap in sources"
    );
    assert!(
        !sources.contains(&RecallEvidencePath::LocusGraph),
        "pure-locus drawer must NOT have LocusGraph (no tunnel points to it)"
    );
}

// ---------------------------------------------------------------------------
// 3. Drawer that is BOTH a locus hit and a tunnel target carries both bits
// ---------------------------------------------------------------------------

/// When drawerA tunnels to drawerB AND drawerB is also a direct locus hit,
/// drawerB's sources must contain BOTH LocusBitmap and LocusGraph.
#[test]
fn drawer_that_is_both_locus_hit_and_tunnel_target_carries_both_bits() {
    let (coord, h) = open_one("3");
    let estate = coord.estate_for(&h).expect("estate");

    let drawer_a = coord
        .capture(&h, capture_frame("source-drawer-A", "room-A"), NOW)
        .expect("capture A");

    let drawer_b = coord
        .capture(&h, capture_frame("target-drawer-B", "room-B"), NOW + 1)
        .expect("capture B");

    // Tunnel from A → B. B is ALSO a direct locus hit (currently-believed).
    // The locus lane merges B with LocusBitmap first; the graph expansion then
    // inserts B into graph_score_map and the attribution step adds LocusGraph.
    estate
        .capture_tunnel(
            tunnel_frame_with_ids("room-A", "room-B", "both-bits-link", &drawer_a.id, &drawer_b.id),
            NOW + 2,
        )
        .expect("capture tunnel");

    let result = coord
        .recall_scored(&h, union_best_request(20), NOW + 3)
        .expect("recall");

    let hit_b = result.hits.iter().find(|h| h.id == drawer_b.id);
    assert!(hit_b.is_some(), "drawerB must appear in results");
    let sources = &hit_b.unwrap().sources;
    assert!(
        sources.contains(&RecallEvidencePath::LocusBitmap),
        "drawerB is a direct locus hit — must have LocusBitmap"
    );
    assert!(
        sources.contains(&RecallEvidencePath::LocusGraph),
        "drawerB is a tunnel target — must also have LocusGraph (got {sources:?})"
    );
}

// ---------------------------------------------------------------------------
// 4. Locus ramp divisor — the normalised locus column, both ports
// ---------------------------------------------------------------------------

/// The unionBest locus ramp divides by `frontier_k`, not by the slice length.
///
/// Three drawers captured oldest to newest form a slice of 3 at a frontier_k of
/// at least 64 (the clamp floor), and a tunnel from the newest to the oldest
/// merges the graph lane's fixed 0.5 onto the oldest by max. After the min-max
/// normalisation the locus column reads 1.0 / 0.5 / 0.0 (newest / middle /
/// oldest): the ramp is 1, (K-1)/K, (K-2)/K, the 0.5 never wins the max, and the
/// middle lands exactly half-way. A slice-length divisor would give
/// 1, 2/3, max(1/3, 0.5) = 0.5, and the middle would normalise to 1/3. The pin
/// holds for every frontier_k of 5 or more. Twin of Swift
/// `locusRampDividesByFrontierKNotSliceLength`.
#[test]
fn locus_ramp_divides_by_frontier_k_not_slice_length() {
    let (coord, h) = open_one("4");
    let estate = coord.estate_for(&h).expect("estate");

    // Content strings sort the same way as capture time (content DESC is the
    // final tiebreak of the stable locus sort), so the slice order is fixed.
    let oldest = coord
        .capture(&h, capture_frame("ramp-1-oldest", "ramp-room"), NOW)
        .expect("capture oldest");
    let middle = coord
        .capture(&h, capture_frame("ramp-2-middle", "ramp-room"), NOW + 1)
        .expect("capture middle");
    let newest = coord
        .capture(&h, capture_frame("ramp-3-newest", "ramp-room"), NOW + 2)
        .expect("capture newest");

    estate
        .capture_tunnel(
            tunnel_frame_with_ids("ramp-room", "ramp-room", "ramp-divisor-link", &newest.id, &oldest.id),
            NOW + 3,
        )
        .expect("capture tunnel");

    let result = coord
        .recall_scored(&h, union_best_request(20), NOW + 4)
        .expect("recall");
    assert_eq!(result.hits.len(), 3, "all three drawers must surface");

    let locus = |id: &str| -> f32 {
        result.hits.iter().find(|h| h.id == id).map(|h| h.score.locus).expect("hit present")
    };
    assert!((locus(&newest.id) - 1.0).abs() < 1e-4, "newest: got {}", locus(&newest.id));
    assert!((locus(&middle.id) - 0.5).abs() < 1e-4, "middle: got {}", locus(&middle.id));
    assert!((locus(&oldest.id) - 0.0).abs() < 1e-4, "oldest: got {}", locus(&oldest.id));
}
