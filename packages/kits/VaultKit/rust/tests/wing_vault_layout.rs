//! wing vault-layout round-trip test.
//!
//! Verifies that:
//!   1. Export produces stable_source_key = `"<wing>/<room>/<slug>"` — wing is
//!      the top-level vault folder.
//!   2. After `ObsidianAdapter::from_ir`, each note's vault path starts with
//!      its wing prefix: `<wing>/<room>/<slug>.md`.
//!   3. Import into a fresh estate writes the expected number of drawers and
//!      preserves room (via frontmatter `room:` round-trip).
//!   4. Wing is restored: each re-imported drawer lands in its original wing,
//!      not in DEFAULT_WING_NAME. This is the proof that `CaptureFrame.wing`
//!      is wired end-to-end through `make_capture_frame`.
//!   5. Re-import is content-idempotent: second pass writes 0, skips
//!      `drawers_skipped_unchanged` == initial count.
//!
//! Mirrors Swift `VaultBridgeTests.wingVaultLayoutRoundTrip`.

use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
};
use vault_kit::{DrawerMapping, ObsidianAdapter, VaultAdapter, VaultBridge, VaultExportScope};
use vault_kit::drawer_mapping::resolve_drawer_node_names;

/// Fixed instant (ms-since-epoch) so tests are deterministic.
const NOW: i64 = 1_765_000_000_000;

/// Open one in-memory estate and return the coordinator + handle.
fn open_one(owner: &str) -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new(owner), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Recall currently-believed drawers (cluster A: active). Mirrors `current_drawers`
/// in sibling test files.
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

/// Build a VaultBridge over the given coordinator.
fn bridge(coord: &mut EstateCoordinator) -> VaultBridge<'_> {
    VaultBridge::new(
        coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::new("wing-layout-test", "test-v1", false),
    )
}

// MARK: - wing organization: wing is the top-level vault folder, and import restores it

/// Capture two drawers in DIFFERENT wings via GLK (CaptureFrame.wing), export the
/// estate, verify the vault layout has one folder per wing, then import into a fresh
/// estate and assert:
///   - each drawer lands back in its ORIGINAL wing (not DEFAULT_WING_NAME)
///   - room is preserved
///   - re-import is content-idempotent
///
/// This test is the proof that CaptureFrame.wing is wired end-to-end through
/// `DrawerMapping::make_capture_frame` (wing organization multi-wing round-trip).
///
/// Mirrors Swift `VaultBridgeTests.wingVaultLayoutRoundTrip`.
#[test]
fn wing_vault_layout_round_trip() {
    // --- Phase 1: build estate and capture two drawers in DIFFERENT wings. ---
    let (coord, handle) = open_one("wing-layout-export");

    // Capture a chemistry note into "User Canon".
    let mut chem_frame = CaptureFrame::new(
        "Aromatics: a study of arene rings and benzene.",
        CaptureChannel::Typed,
        "chemistry",
        LatticeAnchor::udc("000"),
        "wing-layout-test",
        "test-v1",
    );
    chem_frame.wing = Some("User Canon".to_owned());
    coord.capture(&handle, chem_frame, NOW).expect("capture chem into User Canon");

    // Capture a roadmap note into "Personal".
    let mut road_frame = CaptureFrame::new(
        "Project Plan: milestones for Q3 delivery.",
        CaptureChannel::Typed,
        "roadmap",
        LatticeAnchor::udc("000"),
        "wing-layout-test",
        "test-v1",
    );
    road_frame.wing = Some("Personal".to_owned());
    coord.capture(&handle, road_frame, NOW).expect("capture road into Personal");

    // Precondition: two believed drawers, each in its own wing.
    let believed = current_drawers(&coord, &handle);
    assert_eq!(
        believed.len(),
        2,
        "precondition: two believed drawers before export"
    );
    let names_before = resolve_drawer_node_names(&coord, &handle, &believed);
    let wings_before: std::collections::HashSet<String> =
        believed.iter().filter_map(|d| names_before.get(&d.parent_node_id).map(|(w, _)| w.clone())).collect();
    assert!(
        wings_before.contains("User Canon"),
        "precondition: chemistry drawer must land in 'User Canon'; wings: {:?}",
        wings_before
    );
    assert!(
        wings_before.contains("Personal"),
        "precondition: roadmap drawer must land in 'Personal'; wings: {:?}",
        wings_before
    );

    // --- Phase 2: export → verify vault layout (two wing folders). ---
    let mapping = DrawerMapping::new("wing-layout-test", "test-v1", false);
    let projection = mapping
        .export(&coord, &handle, NOW, VaultExportScope::Believed)
        .expect("export");

    assert_eq!(projection.notes.len(), 2, "export must produce 2 NoteIR entries");

    // Every NoteIR stable_source_key must be prefixed by its wing name.
    // "User Canon" note → "User Canon/<room>/<slug>".
    // "Personal" note  → "Personal/<room>/<slug>".
    for note in &projection.notes {
        let slashes = note.stable_source_key.matches('/').count();
        assert!(
            slashes >= 2,
            "stable_source_key must be '<wing>/<room>/<slug>' (≥2 slashes); got '{}'",
            note.stable_source_key
        );
        // Each note's frontmatter wing must prefix its stable_source_key.
        let fm_wing = note.frontmatter.get("wing").map(|s| s.as_str()).unwrap_or("");
        assert!(
            note.stable_source_key.starts_with(fm_wing),
            "stable_source_key '{}' must start with frontmatter wing '{}'",
            note.stable_source_key,
            fm_wing
        );
    }

    // Write vault to a temp directory via ObsidianAdapter to verify filesystem layout.
    let vault_dir = std::env::temp_dir().join(format!(
        "vaultkit-wing-layout-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&vault_dir).expect("create vault dir");

    let adapter = ObsidianAdapter::new();
    adapter
        .from_ir(&projection.notes, &vault_dir)
        .expect("from_ir must write note files");

    // Both wing folders must exist at vault root.
    let user_canon_dir = vault_dir.join("User Canon");
    assert!(
        user_canon_dir.is_dir(),
        "wing folder 'User Canon' must exist as a top-level directory in the vault"
    );
    let personal_dir = vault_dir.join("Personal");
    assert!(
        personal_dir.is_dir(),
        "wing folder 'Personal' must exist as a top-level directory in the vault"
    );

    // No note files (.md) should exist directly at vault root.
    let root_md_count = std::fs::read_dir(&vault_dir)
        .expect("read vault root")
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|x| x == "md").unwrap_or(false))
        .count();
    assert_eq!(
        root_md_count, 0,
        "no .md files must exist at vault root; all notes must live under a wing folder"
    );

    // Room subdirs must be under the correct wing folder.
    assert!(
        user_canon_dir.join("chemistry").is_dir(),
        "'chemistry' room must be a subdirectory under 'User Canon'"
    );
    assert!(
        personal_dir.join("roadmap").is_dir(),
        "'roadmap' room must be a subdirectory under 'Personal'"
    );

    // --- Phase 3: import vault into a FRESH estate. ---
    let (mut coord2, handle2) = open_one("wing-layout-import");
    let first_import = bridge(&mut coord2)
        .import_vault(&vault_dir, &handle2, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("first import");

    assert_eq!(
        first_import.drawers_written, 2,
        "first import must write 2 drawers from the wing vault layout"
    );
    assert_eq!(first_import.drawers_updated, 0, "no updates on first import");
    assert_eq!(
        first_import.drawers_skipped_unchanged, 0,
        "no skips on first import"
    );

    // THE CRITICAL ASSERTION: verify each drawer lands in its ORIGINAL wing.
    // Before CaptureFrame.wing was wired through make_capture_frame, both drawers
    // would land in DEFAULT_WING_NAME ("Agentic Memory") regardless of vault folder.
    let imported = current_drawers(&coord2, &handle2);
    assert_eq!(imported.len(), 2, "two drawers must be active after first import");

    let imported_node_names = resolve_drawer_node_names(&coord2, &handle2, &imported);
    let imported_wings: std::collections::HashSet<String> =
        imported.iter().filter_map(|d| imported_node_names.get(&d.parent_node_id).map(|(w, _)| w.clone())).collect();

    assert!(
        imported_wings.contains("User Canon"),
        "wing round-trip: 'User Canon' drawer must re-import into 'User Canon'; found wings: {:?}",
        imported_wings
    );
    assert!(
        imported_wings.contains("Personal"),
        "wing round-trip: 'Personal' drawer must re-import into 'Personal'; found wings: {:?}",
        imported_wings
    );
    assert!(
        !imported_wings.contains("Agentic Memory"),
        "wing round-trip: no drawer must land in 'Agentic Memory' — each has an explicit wing; found wings: {:?}",
        imported_wings
    );

    // Room preservation: frontmatter `room:` survives export→import.
    let rooms: std::collections::HashSet<String> =
        imported.iter().filter_map(|d| imported_node_names.get(&d.parent_node_id).map(|(_, r)| r.clone())).collect();
    assert!(
        rooms.contains("chemistry"),
        "room 'chemistry' must be preserved through export→import; found rooms: {:?}",
        rooms
    );
    assert!(
        rooms.contains("roadmap"),
        "room 'roadmap' must be preserved through export→import; found rooms: {:?}",
        rooms
    );

    // --- Phase 4: re-import the SAME vault — idempotency. ---
    let second_import = bridge(&mut coord2)
        .import_vault(&vault_dir, &handle2, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("second import (idempotency)");

    assert_eq!(
        second_import.drawers_written, 0,
        "re-import must write 0 drawers (content-idempotent)"
    );
    assert_eq!(second_import.drawers_updated, 0, "re-import must update 0 drawers");
    assert_eq!(
        second_import.drawers_skipped_unchanged, 2,
        "re-import must skip 2 unchanged drawers (content-idempotent)"
    );

    // Estate still has exactly 2 believed drawers after re-import.
    let after_reimport = current_drawers(&coord2, &handle2);
    assert_eq!(
        after_reimport.len(),
        2,
        "estate must still have 2 believed drawers after content-idempotent re-import"
    );

    // Cleanup.
    let _ = std::fs::remove_dir_all(&vault_dir);
}
