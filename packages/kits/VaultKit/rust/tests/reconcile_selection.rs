//! Bridge-level gate-equivalence test for `reconcile_selection` and
//! `import_vault_reconciling` (VR-01 Finding B, bridge layer).
//!
//! Mirrors Swift `VaultBridgeTests.reconcileSelectionMatchesApplySelectedPaths`.
//!
//! **VR-01 Finding B:** apply can only import notes the dry-run would have
//! listed, because both paths run one shared `missing_paths` computation.
//! `reconcile_selection` is the dry-run half (selection, no import);
//! `import_vault_reconciling` is the apply half (selection + import).
//! This test verifies they return the identical selection for identical inputs,
//! and that `reconcile_selection` leaves the estate untouched.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle, EncodeSpeed};
use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use vault_kit::{DrawerMapping, ObsidianAdapter, VaultBridge};

/// Fixed operation instant (ms-since-epoch) — same convention as
/// neighbouring VaultKit tests (e.g. `idempotent_import.rs`).
const NOW: i64 = 1_765_000_000_000;

/// Open one in-memory estate. Returns coordinator + handle.
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("vaultkit-reconcile-selection-tests"), 0, 100)
        .expect("open estate");
    (coord, handle)
}

/// Recall all currently-believed drawers (active, any confirmation/trust tier).
/// Mirrors the `current_drawers` helper in `idempotent_import.rs`.
fn current_drawers(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
) -> Vec<locus_kit::drawer::Drawer> {
    let frame = RecallFrame {
        filter_chain: vec![
            Filter::CurrentlyBelieve,
            Filter::Any(vec![
                Filter::UserConfirmed,
                Filter::Unconfirmed,
                Filter::AutomatedConfirmedOnly,
            ]),
            Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
        ],
        hydration_level: HydrationLevel::Full,
        limit: Some(10_000_000),
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    coord.recall(handle, frame, NOW).expect("recall")
}

/// Write a minimal Markdown note to `vault/rel`. Creates parent dirs as needed.
fn write_note(vault: &PathBuf, rel: &str, text: &str) {
    let path = vault.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).expect("mkdir");
    std::fs::write(path, text).expect("write note");
}

/// VR-01 Finding B, bridge level: `reconcile_selection` (the dry-run's surfaced
/// set) and `import_vault_reconciling` (apply's imported set) must return the
/// identical selection for identical inputs — the review gate holds because both
/// run one shared `missing_paths` computation. Also asserts
/// `reconcile_selection` imports nothing (estate unchanged after dry-run).
///
/// Scenario (empty estate, three notes on disk, one candidate):
///   - `all_paths`   = {ForeignOne.md, ForeignTwo.md, Changed.md}
///   - `candidates`  = {Changed.md}          (caller-declared changed path)
///   - empty estate → both foreign notes are "missing"
///   - surfaced set  = candidates ∪ missing = all three paths
///
/// Mirrors Swift `VaultBridgeTests.reconcileSelectionMatchesApplySelectedPaths`.
#[test]
fn reconcile_selection_matches_apply_selected_paths() {
    let (mut coord, handle) = open_one();

    // Unique vault dir for this test.
    let vault = std::env::temp_dir().join(format!(
        "vaultkit-reconcile-selection-{}",
        uuid::Uuid::new_v4()
    ));

    // Two foreign notes the estate does not hold, plus one candidate
    // (caller-declared changed path) that is also on disk.
    write_note(&vault, "ForeignOne.md", "# Foreign one");
    write_note(&vault, "ForeignTwo.md", "# Foreign two");
    write_note(&vault, "Changed.md",    "# Changed");

    let all_paths: HashSet<String> =
        ["ForeignOne.md", "ForeignTwo.md", "Changed.md"]
            .iter()
            .map(|s| s.to_string())
            .collect();
    let candidates: HashSet<String> =
        ["Changed.md"].iter().map(|s| s.to_string()).collect();

    // --- Dry-run half: reconcile_selection, no import ---
    //
    // VaultBridge::new requires &mut EstateCoordinator.
    // The bridge is scoped so the mutable borrow ends before we recall.
    let surfaced = {
        let mut bridge = VaultBridge::new(
            &mut coord,
            Box::new(ObsidianAdapter::new()),
            DrawerMapping::new("vaultkit-reconcile-selection-tests", "test-v1", false),
        );
        bridge
            .reconcile_selection(&all_paths, &candidates, &handle, NOW)
            .expect("reconcile_selection must succeed on empty estate")
    };

    // reconcile_selection must equal all three paths (empty estate → every
    // non-candidate path is missing; candidates ∪ missing == all_paths).
    assert_eq!(
        surfaced, all_paths,
        "empty estate: candidates ∪ missing must be every vault path; got {:?}",
        surfaced
    );

    // reconcile_selection must import nothing — estate must still be empty.
    let after_dry_run = current_drawers(&coord, &handle);
    assert!(
        after_dry_run.is_empty(),
        "reconcile_selection must import nothing; estate must remain empty; got {} drawer(s)",
        after_dry_run.len()
    );

    // --- Apply half: import_vault_reconciling ---
    //
    // Same inputs → same selection; the import actions exactly that set.
    let (report, selected) = {
        let mut bridge = VaultBridge::new(
            &mut coord,
            Box::new(ObsidianAdapter::new()),
            DrawerMapping::new("vaultkit-reconcile-selection-tests", "test-v1", false),
        );
        bridge
            .import_vault_reconciling(
                &vault,
                &all_paths,
                &candidates,
                &handle,
                NOW,
                None,
                EncodeSpeed::Foreground,
            )
            .expect("import_vault_reconciling must succeed")
    };

    assert_eq!(
        selected, surfaced,
        "apply must import exactly the surfaced set; surfaced {:?}, imported {:?}",
        surfaced, selected
    );
    assert_eq!(
        report.drawers_written, 3,
        "all three notes must land in the estate; got drawers_written={}",
        report.drawers_written
    );

    // --- Convergence: estate now holds every path; missing set collapses ---
    //
    // Empty candidates + full estate → missing set is empty → surfaced set empty.
    let empty_candidates: HashSet<String> = HashSet::new();
    let converged = {
        let mut bridge = VaultBridge::new(
            &mut coord,
            Box::new(ObsidianAdapter::new()),
            DrawerMapping::new("vaultkit-reconcile-selection-tests", "test-v1", false),
        );
        bridge
            .reconcile_selection(&all_paths, &empty_candidates, &handle, NOW)
            .expect("converged reconcile_selection must succeed")
    };
    assert!(
        converged.is_empty(),
        "estate holds every path; missing set must be empty after import; got {:?}",
        converged
    );

    let _ = std::fs::remove_dir_all(&vault);
}
