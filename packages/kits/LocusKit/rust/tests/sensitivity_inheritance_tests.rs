// sensitivity_inheritance_tests.rs
//
// LocusKit store-layer acceptance tests for sensitivity inheritance (§D.1–D.2).
// Rust twin of Swift `SensitivityInheritanceTests.swift`.
//
// These tests drive the two store-layer primitives directly
// (`consolidate_transactionally`, `fold_in_transactionally`) and the Estate
// verb surface (`propose`) to verify that each produces correctly-stamped
// adjective_bitmap values in bits 6–11 per cookbook §2.3.
//
// ## What is tested
//
// - `consolidate_transactionally`: each `_consolidated_from` tunnel is stamped
//   with max(vague, constituent) adjective sensitivity. Mirrors Swift
//   `testConsolidateTunnelCarriesMaxSensitivity`.
// - `fold_in_transactionally`: the supersedes tunnel carries v2's sensitivity;
//   each `_consolidated_from` tunnel carries max(v2, constituent). Mirrors
//   Swift `testFoldInSupersedesTunnelCarriesV2Sensitivity` and
//   `testFoldInConsolidatedFromTunnelsCarryMaxSensitivity`.
// - `Estate::propose`: the returned proposal's adjective sensitivity (bits
//   6–11) mirrors the target drawer's sensitivity tier. Mirrors Swift
//   `testProposalInheritsTargetSensitivity`.
//
// ## Scope
//
// These tests exercise the LocusKit store and Estate verb layers only — they
// do NOT invoke the GeniusLocusKit coordinator or the consolidation cycle.
// The GLK-layer acceptance tests (including the vague-recall ceiling and
// full-cycle max-sensitivity correctness) live in
// `GeniusLocusKit/rust/tests/sensitivity_inheritance_consolidation_tests.rs`.

use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::DrawerFeatureFlags;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use locus_kit::frames::ProposeFrame;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::proposal_operational::ProposalKind;
use std::sync::Arc;
use substrate_kernel::bit_field;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";

// ─── helpers ──────────────────────────────────────────────────────────────────

fn new_store() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(NOW, None).expect("store init")
}

fn make_id() -> String {
    Uuid::new_v4().to_string()
}

/// Create a plain constituent drawer with the given sensitivity in bits 6–11
/// of `adjective_bitmap`. Callers must call `store.add_drawer` before using
/// the ID as a constituent in consolidation.
fn constituent_drawer(sensitivity: AdjectiveSensitivity) -> Drawer {
    let mut d = Drawer::new(
        make_id(),
        "constituent content",
        TEST_PARENT,
        "newton",
        NOW,
        "test-model-v1",
    );
    d.udc_code = "001".to_string();
    // Stamp sensitivity into bits 6–11 of adjective_bitmap (cookbook §2.3).
    d.adjective_bitmap = bit_field::write_field(sensitivity.raw_value(), 0i64, 6, 6);
    d
}

/// Create a vague drawer (IS_VAGUE bit set) with the given sensitivity.
fn vague_drawer(sensitivity: AdjectiveSensitivity) -> Drawer {
    let mut d = Drawer::new(
        make_id(),
        "vague cluster",
        TEST_PARENT,
        "newton",
        NOW,
        "test-model-v1",
    );
    d.udc_code = "001".to_string();
    d.operational_bitmap |= DrawerFeatureFlags::IS_VAGUE;
    // Stamp sensitivity into bits 6–11 of adjective_bitmap (cookbook §2.3).
    d.adjective_bitmap = bit_field::write_field(sensitivity.raw_value(), 0i64, 6, 6);
    d
}

/// Return the `_consolidated_from` tunnel ID between a vague drawer and a
/// constituent: `_consolidated_from:{vague_id}:{constituent_id}`.
fn cf_tunnel_id(vague_id: &str, constituent_id: &str) -> String {
    format!("_consolidated_from:{}:{}", vague_id, constituent_id)
}

/// Return the `supersedes` tunnel ID: `supersedes:{v2_id}:{prior_vague_id}`.
fn supersedes_tunnel_id(v2_id: &str, prior_vague_id: &str) -> String {
    format!("supersedes:{}:{}", v2_id, prior_vague_id)
}

// ─── Test 1: consolidate_transactionally — tunnel stamps ─────────────────────

/// `_consolidated_from` tunnels carry max(vague, constituent) sensitivity
/// (§D.1). Each tunnel is checked individually:
/// - vague=Elevated, constituent=Normal  → max = Elevated
/// - vague=Elevated, constituent=Elevated → max = Elevated
/// - vague=Elevated, constituent=Secret  → max = Secret
///
/// Mirrors Swift `testConsolidateTunnelCarriesMaxSensitivity`.
#[test]
fn consolidate_transactionally_tunnel_carries_max_sensitivity() {
    let store = new_store();

    // Three constituents: below-vague, equal, and above-vague sensitivity.
    let c_normal = constituent_drawer(AdjectiveSensitivity::Normal);
    let c_elevated = constituent_drawer(AdjectiveSensitivity::Elevated);
    let c_secret = constituent_drawer(AdjectiveSensitivity::Secret);

    store.add_drawer(&c_normal, NOW).expect("add c_normal");
    store.add_drawer(&c_elevated, NOW).expect("add c_elevated");
    store.add_drawer(&c_secret, NOW).expect("add c_secret");

    // Vague drawer: Elevated sensitivity (floor for all tunnels that touch a
    // normal constituent; ceiling for constituents below Elevated).
    let vague = vague_drawer(AdjectiveSensitivity::Elevated);
    let vague_id = vague.id.clone();
    let constituent_ids: Vec<&str> = vec![&c_normal.id, &c_elevated.id, &c_secret.id];

    store
        .consolidate_transactionally(&vague, &constituent_ids, "newton", NOW)
        .expect("consolidate_transactionally");

    let all_tunnels = store.all_tunnels().expect("all_tunnels");

    // Verify the three _consolidated_from tunnels.
    let check = |constituent_id: &str, expected: AdjectiveSensitivity| {
        let tid = cf_tunnel_id(&vague_id, constituent_id);
        let t = all_tunnels
            .iter()
            .find(|t| t.id == tid)
            .unwrap_or_else(|| panic!("_consolidated_from tunnel {} not found", tid));
        assert_eq!(
            t.adjective_sensitivity(),
            expected,
            "_consolidated_from:{}:{} expected {:?}, got {:?}",
            vague_id,
            constituent_id,
            expected,
            t.adjective_sensitivity()
        );
    };

    // max(Elevated=16, Normal=0)   = Elevated
    check(&c_normal.id, AdjectiveSensitivity::Elevated);
    // max(Elevated=16, Elevated=16) = Elevated
    check(&c_elevated.id, AdjectiveSensitivity::Elevated);
    // max(Elevated=16, Secret=48)  = Secret
    check(&c_secret.id, AdjectiveSensitivity::Secret);
}

/// When vague sensitivity exceeds every constituent, all tunnels carry the
/// vague tier. Mirrors Swift `testConsolidateTunnelFlooredByVagueSensitivity`.
#[test]
fn consolidate_transactionally_vague_is_floor_when_higher() {
    let store = new_store();

    // All constituents: Normal.
    let c1 = constituent_drawer(AdjectiveSensitivity::Normal);
    let c2 = constituent_drawer(AdjectiveSensitivity::Normal);
    let c3 = constituent_drawer(AdjectiveSensitivity::Normal);

    store.add_drawer(&c1, NOW).expect("add c1");
    store.add_drawer(&c2, NOW).expect("add c2");
    store.add_drawer(&c3, NOW).expect("add c3");

    // Vague: Secret — all tunnels must be floored at Secret.
    let vague = vague_drawer(AdjectiveSensitivity::Secret);
    let vague_id = vague.id.clone();
    let constituent_ids = vec![c1.id.as_str(), c2.id.as_str(), c3.id.as_str()];

    store
        .consolidate_transactionally(&vague, &constituent_ids, "newton", NOW)
        .expect("consolidate_transactionally");

    let all_tunnels = store.all_tunnels().expect("all_tunnels");

    for cid in &[&c1.id, &c2.id, &c3.id] {
        let tid = cf_tunnel_id(&vague_id, cid);
        let t = all_tunnels
            .iter()
            .find(|t| t.id == tid)
            .unwrap_or_else(|| panic!("tunnel {} not found", tid));
        assert_eq!(
            t.adjective_sensitivity(),
            AdjectiveSensitivity::Secret,
            "tunnel {} should be Secret (vague floor), got {:?}",
            tid,
            t.adjective_sensitivity()
        );
    }
}

// ─── Test 2: fold_in_transactionally — tunnel stamps ─────────────────────────

/// `fold_in_transactionally` stamps:
/// - the `supersedes` tunnel with v2's sensitivity
/// - each `_consolidated_from` tunnel with max(v2, constituent) sensitivity
///
/// Mirrors Swift `testFoldInSupersedesTunnelCarriesV2Sensitivity` and
/// `testFoldInConsolidatedFromTunnelsCarryMaxSensitivity`.
#[test]
fn fold_in_transactionally_tunnel_stamps() {
    let store = new_store();

    // Three constituents: Normal, Elevated, Secret.
    let c_normal = constituent_drawer(AdjectiveSensitivity::Normal);
    let c_elevated = constituent_drawer(AdjectiveSensitivity::Elevated);
    let c_secret = constituent_drawer(AdjectiveSensitivity::Secret);

    store.add_drawer(&c_normal, NOW).expect("add c_normal");
    store.add_drawer(&c_elevated, NOW).expect("add c_elevated");
    store.add_drawer(&c_secret, NOW).expect("add c_secret");

    // Prior vague: Normal sensitivity. Add directly to store.
    let prior_vague = vague_drawer(AdjectiveSensitivity::Normal);
    store.add_drawer(&prior_vague, NOW).expect("add prior_vague");
    let prior_vague_id = prior_vague.id.clone();
    let shared_lineage = prior_vague.lineage_id; // v2 must share this

    // v2: Restricted sensitivity; shares lineage with prior vague.
    // fold_in_transactionally checks that vague_v2.lineage_id == prior.lineageID.
    let mut vague_v2 = vague_drawer(AdjectiveSensitivity::Restricted);
    vague_v2.lineage_id = shared_lineage;
    let v2_id = vague_v2.id.clone();

    let enlarged_ids = vec![
        c_normal.id.as_str(),
        c_elevated.id.as_str(),
        c_secret.id.as_str(),
    ];

    store
        .fold_in_transactionally(&vague_v2, &prior_vague_id, &enlarged_ids, "newton", NOW)
        .expect("fold_in_transactionally");

    let all_tunnels = store.all_tunnels().expect("all_tunnels");

    // supersedes tunnel: v2.sensitivity = Restricted.
    let sup_id = supersedes_tunnel_id(&v2_id, &prior_vague_id);
    let sup = all_tunnels
        .iter()
        .find(|t| t.id == sup_id)
        .unwrap_or_else(|| panic!("supersedes tunnel {} not found", sup_id));
    assert_eq!(
        sup.adjective_sensitivity(),
        AdjectiveSensitivity::Restricted,
        "supersedes tunnel must carry v2 sensitivity (Restricted), got {:?}",
        sup.adjective_sensitivity()
    );

    // _consolidated_from tunnels: max(v2=Restricted, constituent).
    let check_cf = |constituent_id: &str, expected: AdjectiveSensitivity| {
        let tid = cf_tunnel_id(&v2_id, constituent_id);
        let t = all_tunnels
            .iter()
            .find(|t| t.id == tid)
            .unwrap_or_else(|| panic!("_consolidated_from tunnel {} not found", tid));
        assert_eq!(
            t.adjective_sensitivity(),
            expected,
            "_consolidated_from:{}:{} expected {:?}, got {:?}",
            v2_id,
            constituent_id,
            expected,
            t.adjective_sensitivity()
        );
    };

    // max(Restricted=32, Normal=0)    = Restricted
    check_cf(&c_normal.id, AdjectiveSensitivity::Restricted);
    // max(Restricted=32, Elevated=16) = Restricted
    check_cf(&c_elevated.id, AdjectiveSensitivity::Restricted);
    // max(Restricted=32, Secret=48)   = Secret
    check_cf(&c_secret.id, AdjectiveSensitivity::Secret);
}

// ─── Test 3: Estate::propose stamps proposal adjective sensitivity ────────────

/// A proposal inherits its target drawer's sensitivity tier in bits 6–11 of
/// `adjective_bitmap` (§D.2). Three tiers verified: Normal, Elevated, Secret.
///
/// Mirrors Swift `testProposalInheritsTargetSensitivity`.
#[test]
fn propose_inherits_target_drawer_sensitivity() {
    // Use all three distinct tiers to verify the proposal stamps each one.
    for sensitivity in [
        AdjectiveSensitivity::Normal,
        AdjectiveSensitivity::Elevated,
        AdjectiveSensitivity::Secret,
    ] {
        let store = Arc::new(new_store()) as Arc<dyn DrawerStore>;
        let estate = Estate::create(store, OwnerCredentials::new("newton"), None)
            .expect("create estate");

        // Capture a drawer with the given sensitivity tier.
        let mut frame = CaptureFrame::new(
            "target content for propose",
            CaptureChannel::Typed,
            "inbox",
            LatticeAnchor::udc("001"),
            "newton",
            "test-model-v1",
        );
        frame.sensitivity = sensitivity;
        let drawer = estate.capture(frame, NOW).expect("capture");

        // Propose against that drawer.
        let proposal = estate
            .propose(ProposeFrame::new(&drawer.id, ProposalKind::MutateDrawer), NOW)
            .expect("propose");

        assert_eq!(
            proposal.adjective_sensitivity(),
            sensitivity,
            "proposal must inherit target sensitivity {:?} (bits 6–11), got {:?}",
            sensitivity,
            proposal.adjective_sensitivity()
        );
    }
}

/// A proposal filed against a Normal (raw 0) target stays Normal even though
/// zero is the default for uninitialised bitmaps — ensuring the stamp path is
/// not accidentally elided for the zero case.
///
/// Mirrors Swift `testProposalNormalTargetStaysNormal`.
#[test]
fn propose_normal_target_stays_normal() {
    let store = Arc::new(new_store()) as Arc<dyn DrawerStore>;
    let estate = Estate::create(store, OwnerCredentials::new("newton"), None)
        .expect("create estate");

    // Capture a Normal-sensitivity drawer (the default).
    let frame = CaptureFrame::new(
        "normal sensitivity target",
        CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("001"),
        "newton",
        "test-model-v1",
    );
    let drawer = estate.capture(frame, NOW).expect("capture");

    let proposal = estate
        .propose(ProposeFrame::new(&drawer.id, ProposalKind::MutateDrawer), NOW)
        .expect("propose");

    assert_eq!(
        proposal.adjective_sensitivity(),
        AdjectiveSensitivity::Normal,
        "proposal against Normal target must stay Normal, got {:?}",
        proposal.adjective_sensitivity()
    );
}
