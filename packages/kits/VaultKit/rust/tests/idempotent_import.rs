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
    adjectives::AdjectiveSensitivity,
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, MutationKind},
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
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
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
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
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
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
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
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
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

// MARK: - Finding 6 regression: moot_id hijack guard

/// Regression for Security Finding 6: a vault file that claims an existing
/// drawer's moot_id but carries DIFFERENT body content must NOT replace that
/// drawer's body. The guard rejects the moot_id claim and files the import
/// under the file's own FNV-derived lineage instead, leaving the victim's
/// drawer untouched and isolating the attacker's content in a new drawer.
///
/// Mirrors Swift `mootIDHijackGuardBlocksBodyReplacement` in VaultBridgeTests.
#[test]
fn moot_id_hijack_guard_blocks_body_replacement() {
    let (mut coord, handle) = open_one();

    // 1. Capture the victim drawer through the normal path.
    let victim_content = "original content that must not be replaced";
    let victim_frame = CaptureFrame::new(
        victim_content,
        CaptureChannel::Typed,
        "target",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    let victim = coord.capture(&handle, victim_frame, NOW).expect("capture victim");

    // 2. Craft a hostile vault file: same moot_id (victim's lineage UUID) but
    //    attacker-supplied body. This simulates an attacker learning the UUID
    //    from a prior export and building a file to overwrite the victim's body.
    let vault = std::env::temp_dir()
        .join(format!("vaultkit-hijack-f6-{}", uuid::Uuid::new_v4()));
    write_note(
        &vault,
        "attack/hostile.md",
        &format!(
            "---\nroom: target\nmoot_id: {}\n---\nattacker-controlled replacement content\n",
            victim.lineage_id
        ),
    );

    // 3. Import the hostile vault file.
    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import hostile vault");

    // 4. The hostile file carries a different body, so the guard fires:
    //    the moot_id claim is rejected and the file lands under its own FNV
    //    lineage. One new drawer is written (the hostile file itself), not an
    //    update to the victim.
    assert_eq!(
        report.drawers_written, 1,
        "hostile file with different body must land as a new drawer, not an update"
    );
    assert_eq!(
        report.drawers_updated, 0,
        "hostile import must not update any existing drawer"
    );

    // 5. The victim's content is completely unchanged.
    let all_frame = RecallFrame {
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
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let all_drawers = coord.recall(&handle, all_frame, NOW).expect("recall all");
    assert_eq!(
        all_drawers.len(), 2,
        "estate must have exactly the victim drawer + the isolated hostile drawer"
    );

    let victim_after = all_drawers
        .iter()
        .find(|d| d.lineage_id == victim.lineage_id)
        .expect("victim lineage must still exist");
    assert_eq!(
        victim_after.content, victim_content,
        "victim drawer content must be unchanged after hostile import"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

/// Finding 6 (all-tier gap): the lineage-hijack guard must fire even when the
/// victim drawer is CONFIRMED (userConfirmed) — not just when it is unconfirmed.
/// Before the fix, `existing_drawer_state` used `filter_chain: vec![Filter::Unconfirmed]`,
/// so confirmed lineages were invisible to the collision set and a hostile note
/// claiming a confirmed lineage with different content would bypass the guard.
///
/// Mirrors Swift `mootIDHijackGuardBlocksBodyReplacementOnConfirmedLineage`.
#[test]
fn moot_id_hijack_guard_blocks_body_replacement_on_confirmed_lineage() {
    let (mut coord, handle) = open_one();

    // 1. Capture the victim drawer and confirm it (moves from unconfirmed → userConfirmed).
    let victim_content = "confirmed content that a hostile note must not replace";
    let victim_frame = CaptureFrame::new(
        victim_content,
        CaptureChannel::Typed,
        "secure",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    let victim = coord.capture(&handle, victim_frame, NOW).expect("capture victim");
    // Confirm the drawer — moves it out of the unconfirmed pool.
    // Before the fix, existing_drawer_state only scanned [Filter::Unconfirmed], so
    // confirmed lineage IDs were invisible to the collision guard.
    coord
        .mutate(&handle, &victim.id, MutationKind::Confirm, None)
        .expect("confirm victim");

    // 2. Craft a hostile vault file: claims victim's lineage_id, different body, foreign path.
    let vault = std::env::temp_dir()
        .join(format!("vaultkit-hijack-confirmed-{}", uuid::Uuid::new_v4()));
    write_note(
        &vault,
        "attack/confirmed-hijack.md",
        &format!(
            "---\nroom: secure\nmoot_id: {}\n---\nattacker-controlled replacement content targeting a confirmed drawer\n",
            victim.lineage_id
        ),
    );

    // 3. Import the hostile vault file.
    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import hostile vault");

    // 4. Guard must have fired: hostile lands as a NEW drawer (moot_id claim rejected).
    assert_eq!(
        report.drawers_written, 1,
        "hostile file must land as a new drawer, not an update to the confirmed victim"
    );
    assert_eq!(
        report.drawers_updated, 0,
        "hostile import must not update the confirmed victim"
    );

    // 5. Victim's content must be completely unchanged.
    let all_frame = RecallFrame {
        filter_chain: vec![
            Filter::CurrentlyBelieve,
            Filter::Any(vec![
                Filter::UserConfirmed,
                Filter::Unconfirmed,
                Filter::AutomatedConfirmedOnly,
            ]),
            Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ],
        hydration_level: HydrationLevel::Full,
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let all_drawers = coord.recall(&handle, all_frame, NOW).expect("recall all");
    assert_eq!(
        all_drawers.len(), 2,
        "estate must have the confirmed victim + the isolated hostile drawer"
    );
    let victim_after = all_drawers
        .iter()
        .find(|d| d.lineage_id == victim.lineage_id)
        .expect("confirmed victim lineage must still exist");
    assert_eq!(
        victim_after.content, victim_content,
        "confirmed victim drawer content must be unchanged after hostile import"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

/// Finding 6 (all-tier gap): the lineage-hijack guard must fire even when the
/// victim drawer has elevated sensitivity (Restricted). Before the fix,
/// `existing_drawer_state` used `filter_chain: vec![Filter::Unconfirmed]` which
/// excluded restricted/secret drawers (default sensitivity ceiling), so a hostile
/// note could claim those lineage IDs and bypass the guard.
///
/// Mirrors Swift `mootIDHijackGuardBlocksBodyReplacementOnRestrictedLineage`.
#[test]
fn moot_id_hijack_guard_blocks_body_replacement_on_restricted_lineage() {
    let (mut coord, handle) = open_one();

    // 1. Capture the victim drawer at restricted sensitivity tier.
    let victim_content = "restricted content that must never be overwritten by a hostile import";
    let mut victim_frame = CaptureFrame::new(
        victim_content,
        CaptureChannel::Typed,
        "classified",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    // Restricted tier: invisible to the default recall ceiling.
    // Before the fix, existing_drawer_state scanned only [Filter::Unconfirmed]
    // (with no sensitivity override) and thus could not see restricted drawers.
    victim_frame.sensitivity = AdjectiveSensitivity::Restricted;
    let victim = coord.capture(&handle, victim_frame, NOW).expect("capture restricted victim");

    // 2. Craft a hostile vault file: claims victim's lineage_id, different body, foreign path.
    let vault = std::env::temp_dir()
        .join(format!("vaultkit-hijack-restricted-{}", uuid::Uuid::new_v4()));
    write_note(
        &vault,
        "attack/restricted-hijack.md",
        &format!(
            "---\nroom: classified\nmoot_id: {}\nsensitivity: restricted\n---\nattacker-controlled replacement content targeting a restricted drawer\n",
            victim.lineage_id
        ),
    );

    // 3. Import the hostile vault file.
    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import hostile vault");

    // 4. Guard must have fired: hostile lands as a NEW drawer.
    assert_eq!(
        report.drawers_written, 1,
        "hostile file must land as a new drawer, not an update to the restricted victim"
    );
    assert_eq!(
        report.drawers_updated, 0,
        "hostile import must not update the restricted victim"
    );

    // 5. Victim's content must be unchanged. Include restricted drawers via
    //    SensitivityAtMost(Secret) — the same filter existing_drawer_state now uses.
    let all_frame = RecallFrame {
        filter_chain: vec![
            Filter::CurrentlyBelieve,
            Filter::Any(vec![
                Filter::UserConfirmed,
                Filter::Unconfirmed,
                Filter::AutomatedConfirmedOnly,
            ]),
            Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ],
        hydration_level: HydrationLevel::Full,
        limit: None,
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let all_drawers = coord.recall(&handle, all_frame, NOW).expect("recall all");
    assert_eq!(
        all_drawers.len(), 2,
        "estate must have the restricted victim + the isolated hostile drawer"
    );
    let victim_after = all_drawers
        .iter()
        .find(|d| d.lineage_id == victim.lineage_id)
        .expect("restricted victim lineage must still exist");
    assert_eq!(
        victim_after.content, victim_content,
        "restricted victim drawer content must be unchanged after hostile import"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

// MARK: - Part B: encode-enqueue sweep after bulk import (no-Corpus path)

/// `ImportReport.enqueued_for_encode` must be 0 when the estate has no
/// registered Corpus (the LocusOnly path). This verifies the field exists on
/// `ImportReport`, the `collect_reindex_jobs` guard returns `None`, and the
/// vault import completes without error.
///
/// The provisioned-Corpus path (enqueued > 0) is covered by the Swift
/// `bulkVaultImportEnqueuesDrawersForEncode` test in `VaultBridgeTests.swift`
/// and the GLK Rust `encode_intake_parity.rs` suite which exercises
/// `collect_reindex_jobs` directly.
#[test]
fn bulk_import_enqueued_for_encode_is_zero_without_corpus() {
    let (mut coord, handle) = open_one();
    let vault = seed_vault("encode-enqueue");

    // Import the vault into an estate with no Corpus (open_one uses a plain
    // InMemoryDrawerStore, no Corpus provisioned). collect_reindex_jobs returns
    // None → enqueued_for_encode stays 0.
    let report = bridge(&mut coord)
        .import_vault(&vault, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import must succeed even without a Corpus");

    assert_eq!(report.drawers_written, 1, "one note must be written");
    assert_eq!(
        report.enqueued_for_encode, 0,
        "no Corpus → enqueued_for_encode must be 0 (not an error)"
    );

    let _ = std::fs::remove_dir_all(&vault);
}
