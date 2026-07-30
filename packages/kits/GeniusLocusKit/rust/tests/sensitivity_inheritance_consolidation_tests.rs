// sensitivity_inheritance_consolidation_tests.rs
//
// Rust twin of Swift `SensitivityInheritanceConsolidationTests` (§D.1, §D.3).
// Tests sensitivity inheritance at the GeniusLocusKit layer:
//
//   1. Mixed-sensitivity cluster → vague drawer carries max constituent tier.
//   2. Fold-in monotone ceiling: adding normal items to a restricted vague item
//      must not lower the tier (v2 must still carry restricted).
//   3. Secret vague item is invisible to vague_recall hop-1 (§D.3 ≤ elevated
//      ceiling added in §D.3).
//   4. Elevated vague item IS visible to vague_recall hop-1.
//
// Uses the same estate provisioning pattern as consolidation_cycle_tests.rs.

use std::sync::Arc;

use genius_locus_kit::brain::consolidation_cycle::ConsolidationConfig;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_operational::{CaptureChannel, DrawerFeatureFlags};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;
use vectorkit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_000;
const DAY: i64 = 86_400;

// Near-identical bodies that cluster together under the deterministic fingerprint model.
const CLUSTER_BODIES: [&str; 4] = [
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist now.",
    "Project Falcon deadline moved to March again. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target remains the staging cluster. Maria owns the Falcon rollout checklist.",
];

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("sens-consolidation-tests"), 0, 100)
        .expect("open estate");
    let vs_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = Arc::new(VectorStore::open(vs_storage).expect("VectorStore::open"));
    coord.register_vector_store(&handle, vector_store);
    let c_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(c_storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("Corpus::open"),
    );
    coord.register_corpus(&handle, corpus);
    (coord, handle)
}

/// Capture a drawer with a given body and adjective sensitivity tier.
fn capture_with_sensitivity(
    coord: &EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    body: &str,
    sensitivity: AdjectiveSensitivity,
    at: i64,
) -> String {
    let mut frame = CaptureFrame::new(
        body,
        CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("000"),
        "sens-test",
        "test-model-v1",
    );
    // CaptureFrame.sensitivity is the adjective sensitivity field (cookbook §2.3 bits 6–11).
    frame.sensitivity = sensitivity;
    coord.capture(handle, frame, at).expect("capture").id
}

/// Sweep: distill then consolidate at 91 days out.
fn sweep(
    coord: &EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    aged: i64,
    config: &ConsolidationConfig,
) -> usize {
    coord
        .distill_items_sweep(handle, aged - DAY, None)
        .expect("distill sweep");
    coord
        .consolidation_sweep(handle, aged, config, None)
        .expect("consolidation sweep")
}

// ── 1. Mixed-sensitivity cluster ──────────────────────────────────────────

#[test]
fn mixed_sensitivity_cluster_vague_carries_max() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    // Three normal + one restricted item that cluster together.
    for body in CLUSTER_BODIES.iter().take(3) {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Normal, NOW);
    }
    capture_with_sensitivity(&coord, &handle, CLUSTER_BODIES[3], AdjectiveSensitivity::Restricted, NOW + 1);

    let produced = sweep(&coord, &handle, aged, &ConsolidationConfig::default());
    assert_eq!(produced, 1, "cluster must produce exactly one vague item");

    // The vague drawer must carry .restricted (max of normal and restricted).
    let all = coord.all_drawers(&handle).expect("all drawers");
    let vague = all.iter().find(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0)
        .expect("vague drawer must exist");
    assert_eq!(
        vague.adjective_sensitivity(),
        AdjectiveSensitivity::Restricted,
        "vague drawer must carry .restricted (max over constituents)"
    );
}

#[test]
fn all_normal_cluster_vague_stays_normal() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    for (i, body) in CLUSTER_BODIES.iter().enumerate() {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Normal, NOW + i as i64);
    }

    let produced = sweep(&coord, &handle, aged, &ConsolidationConfig::default());
    assert_eq!(produced, 1);

    let all = coord.all_drawers(&handle).expect("all drawers");
    let vague = all.iter().find(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0)
        .expect("vague drawer must exist");
    assert_eq!(
        vague.adjective_sensitivity(),
        AdjectiveSensitivity::Normal,
        "all-normal cluster must produce a .normal vague drawer"
    );
}

// ── 2. Fold-in monotone ceiling ───────────────────────────────────────────

#[test]
fn fold_in_monotone_ceiling_does_not_lower_tier() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    // Initial cluster: 3 normal + 1 restricted → vague at restricted.
    for body in CLUSTER_BODIES.iter().take(3) {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Normal, NOW);
    }
    capture_with_sensitivity(&coord, &handle, CLUSTER_BODIES[3], AdjectiveSensitivity::Restricted, NOW + 1);

    sweep(&coord, &handle, aged, &ConsolidationConfig::default());

    // A fifth NORMAL item arrives and folds in.
    let fifth = "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria confirmed the Falcon rollout checklist.";
    capture_with_sensitivity(&coord, &handle, fifth, AdjectiveSensitivity::Normal, aged + 1);
    coord
        .distill_items_sweep(&handle, aged + 3_600, None)
        .expect("distill fifth");

    let mut fold_config = ConsolidationConfig::default();
    fold_config.hamming_ceiling = Some(90);
    let report = coord
        .consolidation_sweep_report(&handle, aged + 92 * DAY, &fold_config, None)
        .expect("fold sweep report");
    assert_eq!(report.fold_ins, 1, "fifth item must fold into existing vague item");

    // The v2 vague drawer must still carry .restricted — fold-in must not lower tier.
    let all = coord.all_drawers(&handle).expect("all drawers");
    let active_vague: Vec<_> = all.iter()
        .filter(|d| {
            (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0
                && d.state() != locus_kit::adjectives::State::Superseded
        })
        .collect();
    let v2 = active_vague.first().expect("one active vague version must exist");
    assert_eq!(
        v2.adjective_sensitivity(),
        AdjectiveSensitivity::Restricted,
        "fold-in into a restricted vague item must not lower the tier below .restricted"
    );
}

// ── 3. Secret vague item invisible to vague_recall (§D.3) ────────────────

#[test]
fn secret_vague_invisible_to_vague_recall() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    // Four secret items that cluster together.
    for (i, body) in CLUSTER_BODIES.iter().enumerate() {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Secret, NOW + i as i64);
    }

    let produced = sweep(&coord, &handle, aged, &ConsolidationConfig::default());
    assert_eq!(produced, 1, "cluster must produce one vague item");

    // Verify the vague item is secret.
    let all = coord.all_drawers(&handle).expect("all drawers");
    let vague = all.iter().find(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0)
        .expect("vague drawer must exist");
    assert_eq!(
        vague.adjective_sensitivity(),
        AdjectiveSensitivity::Secret,
        "secret cluster must produce a .secret vague drawer"
    );

    // vague_recall must NOT return the secret vague item in hop-1 (§D.3 ceiling).
    let result = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 10, 5, 20)
        .expect("vague_recall");
    let has_secret_hit = result.vague_hits.iter()
        .any(|d| d.adjective_sensitivity() == AdjectiveSensitivity::Secret);
    assert!(
        !has_secret_hit,
        "vague_recall hop-1 must not surface .secret vague items (≤ .elevated ceiling)"
    );
    // Hop-2 constituents must not include secret items surfaced via hop-1 leakage.
    let has_secret_constituent_via_hop1 = result.constituents.iter()
        .any(|d| d.adjective_sensitivity() == AdjectiveSensitivity::Secret);
    assert!(
        !has_secret_constituent_via_hop1,
        "hop-2 must not surface .secret constituents via a .secret vague item (hop-1 gates)"
    );
}

// ── 4. Elevated vague item IS visible to vague_recall (§D.3) ─────────────

#[test]
fn elevated_vague_visible_to_vague_recall() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    for (i, body) in CLUSTER_BODIES.iter().enumerate() {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Elevated, NOW + i as i64);
    }

    sweep(&coord, &handle, aged, &ConsolidationConfig::default());

    let result = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 10, 5, 20)
        .expect("vague_recall");
    let has_elevated_hit = result.vague_hits.iter()
        .any(|d| d.adjective_sensitivity() == AdjectiveSensitivity::Elevated);
    assert!(
        has_elevated_hit,
        "vague_recall hop-1 must surface .elevated vague items (≤ .elevated ceiling allows it)"
    );
}

// ── 5. Lineage tunnels carry max sensitivity stamp ────────────────────────

#[test]
fn consolidated_from_tunnels_carry_max_sensitivity() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    // Three normal + one restricted constituent.
    for body in CLUSTER_BODIES.iter().take(3) {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Normal, NOW);
    }
    capture_with_sensitivity(&coord, &handle, CLUSTER_BODIES[3], AdjectiveSensitivity::Restricted, NOW + 1);

    sweep(&coord, &handle, aged, &ConsolidationConfig::default());

    let all_drawers = coord.all_drawers(&handle).expect("all drawers");
    let vague = all_drawers.iter()
        .find(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0)
        .expect("vague drawer must exist");

    let all_tunnels = coord.all_tunnels(&handle).expect("all tunnels");
    let cf_tunnels: Vec<_> = all_tunnels.iter()
        .filter(|t| t.label == "_consolidated_from" && t.source_drawer_id.as_deref() == Some(&vague.id))
        .collect();

    assert!(!cf_tunnels.is_empty(), "_consolidated_from tunnels must exist");

    // At least one tunnel (to the restricted constituent) must carry .restricted.
    let has_restricted_tunnel = cf_tunnels.iter()
        .any(|t| t.adjective_sensitivity() == AdjectiveSensitivity::Restricted);
    assert!(
        has_restricted_tunnel,
        "_consolidated_from tunnel to restricted constituent must carry .restricted tier"
    );
}

// ── 6. Repair prologue (§D.6 #4): under-tiered vague row is repaired ──────
//
// Scenario: a vague drawer whose adjective bitmap was zeroed (simulating a
// row consolidated before sensitivity inheritance shipped) is detected and
// promoted by the repair prologue on the NEXT sweep. A second sweep is
// idempotent (repaired_items == 0).

#[test]
fn repair_prologue_under_tiered_vague_is_repaired() {
    let (coord, handle) = open_one();
    let aged = NOW + 91 * DAY;

    // Step 1: produce a correctly-stamped restricted vague item.
    for body in CLUSTER_BODIES.iter().take(3) {
        capture_with_sensitivity(&coord, &handle, body, AdjectiveSensitivity::Normal, NOW);
    }
    capture_with_sensitivity(
        &coord, &handle, CLUSTER_BODIES[3], AdjectiveSensitivity::Restricted, NOW + 1);

    let produced = sweep(&coord, &handle, aged, &ConsolidationConfig::default());
    assert_eq!(produced, 1, "setup: cluster must consolidate to one vague item");

    // Capture the vague drawer's ID before corrupting it.
    let vague_id = {
        let all = coord.all_drawers(&handle).expect("all drawers");
        all.iter()
            .find(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0)
            .expect("vague drawer must exist after setup")
            .id.clone()
    };

    // Step 2: zero the adjective bitmap to simulate a pre-inheritance-era row.
    // adjective_sensitivity() reads bits 6–11; zeroing the full bitmap drops
    // the vague drawer's tier to Normal while constituents remain Restricted.
    {
        let estate = coord.estate_for(&handle).expect("estate");
        estate.repair_adjective_bitmap(&vague_id, 0, aged)
            .expect("corrupt vague drawer adjective bitmap");
    }

    // Confirm the corruption: the drawer must now appear as Normal.
    let corrupted = coord.all_drawers(&handle).expect("all drawers after corrupt");
    let vd_corrupt = corrupted.iter()
        .find(|d| d.id == vague_id)
        .expect("vague drawer still present");
    assert_eq!(
        vd_corrupt.adjective_sensitivity(),
        AdjectiveSensitivity::Normal,
        "zeroed bitmap must make the vague drawer appear Normal (under-tiered)"
    );

    // Step 3: sweep 1 — repair prologue must detect and promote the vague drawer.
    let report1 = coord
        .consolidation_sweep_report(
            &handle, aged + DAY, &ConsolidationConfig::default(), None)
        .expect("sweep 1 consolidation_sweep_report");
    assert_eq!(
        report1.repaired_items, 1,
        "sweep 1: repair prologue must report exactly one repaired vague drawer"
    );

    // The vague drawer must now carry Restricted (max over its constituents).
    let after_repair = coord.all_drawers(&handle).expect("all drawers after repair");
    let vd_repaired = after_repair.iter()
        .find(|d| d.id == vague_id)
        .expect("vague drawer still present after repair");
    assert_eq!(
        vd_repaired.adjective_sensitivity(),
        AdjectiveSensitivity::Restricted,
        "after repair: vague drawer must carry Restricted (max over constituents)"
    );

    // All _consolidated_from tunnels for this vague item must also carry Restricted.
    let all_tunnels = coord.all_tunnels(&handle).expect("all tunnels");
    let cf_tunnels: Vec<_> = all_tunnels.iter()
        .filter(|t| {
            t.label == "_consolidated_from"
                && t.source_drawer_id.as_deref() == Some(vague_id.as_str())
        })
        .collect();
    assert!(!cf_tunnels.is_empty(),
        "_consolidated_from tunnels must exist for the repaired vague item");
    assert!(
        cf_tunnels.iter().all(|t| t.adjective_sensitivity() == AdjectiveSensitivity::Restricted),
        "all _consolidated_from tunnels must carry Restricted after repair"
    );

    // Step 4: sweep 2 — idempotent; the estate is now correctly stamped.
    let report2 = coord
        .consolidation_sweep_report(
            &handle, aged + 2 * DAY, &ConsolidationConfig::default(), None)
        .expect("sweep 2 consolidation_sweep_report");
    assert_eq!(
        report2.repaired_items, 0,
        "sweep 2: repair prologue must be idempotent (zero repairs on correctly-stamped estate)"
    );
}
