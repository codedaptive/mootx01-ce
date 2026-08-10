//! Regression test for VK-EXPORT-FIX: DrawerMapping::export must return ALL
//! believed drawers, not just the first page-sized slice.
//!
//! In the Swift port the GLK convenience overload `recall(_:_:RecallFrame)`
//! defaulted `GLKRecallRequest.limit` to 50 when `RecallFrame.limit` was
//! `None`, silently capping export at 50 drawers.
//!
//! `DrawerMapping::export` passes `limit: Some(10_000_000)` to the recall
//! frame, producing a full-scan projection that drains all pages regardless
//! of `RecallStream::DEFAULT_PAGE_SIZE` (50). This test protects that
//! invariant: an estate with more than 50 believed drawers must be fully
//! exported, with the exported NoteIR count equalling the drawer count.

use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    dataset_handle::IMPORT_EMBEDDING_MODEL_ID,
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use vault_kit::{DrawerMapping, VaultExportScope};

const NOW: i64 = 1_700_000_000_000; // 2023-11-14 ms-since-epoch

/// Open one in-memory estate. Mirrors the `open_one()` helper in the
/// GeniusLocusKit coordinator tests.
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("vaultkit-export-cap-test"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Minimal `CaptureFrame` that satisfies I-5 (all five fields non-empty).
fn cap_frame(i: usize) -> CaptureFrame {
    CaptureFrame::new(
        format!("Drawer {i}: synthetic content for the VK-EXPORT-FIX regression test."),
        CaptureChannel::ImportedFile,
        "export-regression",
        LatticeAnchor::udc("000"),
        "vaultkit-test",
        IMPORT_EMBEDDING_MODEL_ID,
    )
}

/// Recall all believed drawers without a 50-cap. This mirrors the precondition
/// check in the Swift `exportExceedsDefaultCapOf50` test, explicitly requesting
/// an unbounded result to verify the substrate state.
fn recall_all_believed(coord: &EstateCoordinator, handle: &EstateHandle) -> usize {
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
        hydration_level: HydrationLevel::BitmapOnly,
        // Use a very large explicit limit to bypass the GLK coordinator's
        // `frame.limit.unwrap_or(50)` default (EstateCoordinator::recall caps an
        // unset limit at 50, mirroring Swift `VerbSurface.recall`'s `?? 50`). The
        // precondition needs the true substrate count, so it must request an
        // unbounded result explicitly — mirrors the Swift test's `limit: 10_000_000`.
        limit: Some(10_000_000),
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    coord
        .recall(handle, frame, NOW)
        .expect("recall all believed")
        .len()
}

// MARK: - VK-EXPORT-FAILOUD: bricked-estate detection

/// Export of a genuinely empty estate must succeed with 0 notes, not return
/// an `ExportBrickedEstate` error. An empty estate has zero drawer rows in
/// storage so the two-step bricked check (COUNT(*) = 0) short-circuits.
///
/// Mirrors Swift `VaultBridgeTests.exportOfEmptyEstateSucceedsWithZeroNotes`.
#[test]
fn export_of_genuinely_empty_estate_returns_zero_notes_not_bricked_error() {
    let (coord, handle) = open_one();
    // No drawers captured — the estate is genuinely empty.
    let mapping = DrawerMapping::default();
    let result = mapping.export(&coord, &handle, NOW, VaultExportScope::Believed);
    let projection = result.expect("empty estate export must not return an error");
    assert_eq!(
        projection.notes.len(),
        0,
        "genuinely empty estate must export 0 notes"
    );
}

// MARK: - VK-EXPORT-CAP regression

/// Regression test: export an estate with >50 believed drawers and assert
/// that every drawer is present in the NoteIR result.
///
/// Mirrors the Swift `VaultBridgeTests.exportExceedsDefaultCapOf50` test.
/// The Rust port does NOT have the 50-cap bug (collect_all drains all pages),
/// so this test is expected to be green both before and after the Swift fix.
/// It is included here to protect the parity invariant: if the Rust recall
/// path were ever changed to apply a default cap, this test would catch it.
#[test]
fn export_returns_all_drawers_exceeding_default_cap() {
    let (coord, handle) = open_one();
    let target_count = 60;

    // Capture 60 believed drawers directly via the coordinator.
    for i in 0..target_count {
        coord
            .capture(&handle, cap_frame(i), NOW)
            .expect("capture");
    }

    // Precondition: verify 60 drawers are in the estate.
    let believed_count = recall_all_believed(&coord, &handle);
    assert_eq!(
        believed_count, target_count,
        "precondition: {target_count} believed drawers must be captured; got {believed_count}"
    );

    // Export via DrawerMapping::export. The Rust path uses limit: None which
    // drives collect_all, so all rows are returned without a 50-cap.
    let mapping = DrawerMapping::default();
    let notes = mapping
        .export(&coord, &handle, NOW, VaultExportScope::Believed)
        .expect("export")
        .notes;

    // THE CRITICAL ASSERTION: every believed drawer must appear in the export.
    // In the Rust port this should always pass (no 50-cap). In a hypothetical
    // future change that introduces a default cap, this assertion would fail.
    assert_eq!(
        notes.len(),
        believed_count,
        "export must return all {believed_count} believed drawers; got {} (50-cap defect if <60)",
        notes.len()
    );
}
