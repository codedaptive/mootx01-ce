//! Non-resurrection tests for the vault import guard.
//!
//! Mirrors Swift `VaultBridgeTests` `FINDING-1: content-idempotent +
//! tombstone-aware import` section, covering both belief-cluster variants
//! the import guard must block:
//!
//!   - **Cluster B (withdrawn):** drawer moved to `withdrawn` state via the
//!     `withdraw` verb (`tombstoned_at IS NULL`, state = 18, surfaced by
//!     `UsedToBelieve`). Re-import must not resurrect it.
//!
//!   - **Cluster C (erased/tombstoned):** drawer permanently erased via the
//!     `expunge` verb (`tombstoned_at IS NOT NULL`, state ≥ 32, invisible to
//!     the recall pipeline). Re-import must not resurrect it. This is the gap
//!     the prior fix (FINDING-1b) left open: `UsedToBelieve` only covers
//!     cluster B, not cluster C.
//!
//! The cluster C fix adds `EstateCoordinator::tombstoned_lineage_ids`, which
//! uses `Estate::all_drawers()` — the only scan that includes tombstoned rows.
//! `VaultBridge::existing_tombstoned_lineage_ids` now unions cluster B and
//! cluster C so both are blocked.

use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use vault_kit::{DrawerMapping, ObsidianAdapter, VaultBridge};

/// Fixed operation instant (ms-since-epoch) so tests are deterministic.
const NOW: i64 = 1_765_000_000_000;

/// Open one in-memory estate and return the coordinator + handle.
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("vaultkit-idempotent-tests"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Write a minimal Markdown note to `vault/rel`.
fn write_note(vault: &PathBuf, rel: &str, text: &str) {
    let path = vault.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).expect("mkdir");
    std::fs::write(path, text).expect("write note");
}

/// Seed a one-note vault at a temp path and return its path.
fn seed_vault(tag: &str) -> PathBuf {
    let vault = std::env::temp_dir()
        .join(format!("vaultkit-idempotent-{}-{}", tag, uuid::Uuid::new_v4()));
    write_note(
        &vault,
        "Chem/Aromatics.md",
        "---\nroom: research\n---\nA study of [[Benzene]] and its ring structure.\n",
    );
    vault
}

/// Recall currently-believed drawers (cluster A: active, both confirmed and
/// unconfirmed, all trust levels). Mirrors Swift `currentDrawers`.
fn current_drawers(coord: &EstateCoordinator, handle: &EstateHandle) -> Vec<locus_kit::drawer::Drawer> {
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

/// Build a VaultBridge over the given coordinator.
fn bridge(coord: &mut EstateCoordinator) -> VaultBridge<'_> {
    VaultBridge::new(
        coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::new("vaultkit-idempotent-tests", "test-v1", false),
    )
}

// MARK: - Cluster B: withdrawn (usedToBelieve)

/// Re-importing a note whose drawer was WITHDRAWN must not resurrect it.
/// Mirrors Swift `reimportAfterWithdrawDoesNotResurrect`.
#[test]
fn reimport_after_withdraw_does_not_resurrect() {
    let (mut coord, handle) = open_one();
    let vault = seed_vault("withdraw");

    // First import: note lands as a new drawer.
    let first = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW)
        .expect("first import");
    assert_eq!(first.drawers_written, 1, "first import must write the drawer");
    assert_eq!(first.drawers_updated, 0);

    // Retrieve the active drawer and withdraw it (cluster B, tombstoned_at IS NULL).
    let active = current_drawers(&coord, &handle);
    assert_eq!(active.len(), 1, "one active drawer before withdraw");
    let row_id = active[0].id.clone();
    coord
        .withdraw(&handle, &row_id, Some("test-withdrawal"), NOW)
        .expect("withdraw");

    // The estate is now empty of active drawers.
    let after_withdraw = current_drawers(&coord, &handle);
    assert!(after_withdraw.is_empty(), "no active drawers after withdraw");

    // Re-import the SAME vault. The lineage is in the withdrawn (cluster B) set.
    // The import must NOT resurrect it.
    let second = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW)
        .expect("second import");
    assert_eq!(
        second.drawers_written, 0,
        "withdrawn note must NOT be resurrected on re-import (cluster B)"
    );
    assert_eq!(second.drawers_updated, 0);
    assert_eq!(
        second.drawers_skipped_tombstoned, 1,
        "withdrawn lineage must be counted as skipped-tombstoned"
    );

    // Estate must remain empty.
    let after_reimport = current_drawers(&coord, &handle);
    assert!(
        after_reimport.is_empty(),
        "estate must remain empty after re-import of withdrawn lineage"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

// MARK: - Cluster C: erased/tombstoned (expunge / moot_erase_memory)

/// Re-importing a note whose drawer was ERASED via `expunge` (moot_erase_memory)
/// must not resurrect it. This is the gap the prior FINDING-1b fix left open:
/// `UsedToBelieve` only covers cluster B (tombstoned_at IS NULL). Cluster C rows
/// (tombstoned_at IS NOT NULL) are invisible to the recall pipeline and were
/// silently resurrected before this fix.
///
/// Mirrors Swift `reimportAfterExpungeDoesNotResurrect` (FINDING-1b cluster C).
#[test]
fn reimport_after_expunge_does_not_resurrect() {
    let (mut coord, handle) = open_one();
    let vault = seed_vault("expunge");

    // First import: note lands as a new drawer.
    let first = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW)
        .expect("first import");
    assert_eq!(first.drawers_written, 1, "first import must write the drawer");

    // Retrieve the active drawer and EXPUNGE it (cluster C: tombstoned_at IS NOT NULL,
    // content blob zeroed). This mirrors `moot_erase_memory` — the verb that triggered
    // the resurrection bug in the original transcript.
    let active = current_drawers(&coord, &handle);
    assert_eq!(active.len(), 1, "one active drawer before expunge");
    let row_id = active[0].id.clone();
    coord
        .expunge(&handle, &row_id, "test-expunge", true, NOW)
        .expect("expunge");

    // The estate is now empty of active drawers (recall only sees non-tombstoned rows).
    let after_expunge = current_drawers(&coord, &handle);
    assert!(after_expunge.is_empty(), "no active drawers after expunge");

    // Re-import the SAME vault. The lineage is in the erased (cluster C) set,
    // which is invisible to recall but visible via EstateCoordinator::tombstoned_lineage_ids.
    // Before the fix: drawers_written == 1 (resurrection bug).
    // After the fix:  drawers_written == 0, drawers_skipped_tombstoned == 1.
    let second = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW)
        .expect("second import");
    assert_eq!(
        second.drawers_written, 0,
        "erased note must NOT be resurrected on re-import — cluster C gap (moot_erase_memory)"
    );
    assert_eq!(second.drawers_updated, 0);
    assert_eq!(
        second.drawers_skipped_tombstoned, 1,
        "erased lineage must be counted as skipped-tombstoned"
    );

    // Estate must remain empty.
    let after_reimport = current_drawers(&coord, &handle);
    assert!(
        after_reimport.is_empty(),
        "estate must remain empty after re-import of erased (expunged) lineage"
    );

    let _ = std::fs::remove_dir_all(&vault);
}
