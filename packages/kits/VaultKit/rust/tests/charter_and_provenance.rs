//! Tests for Bug M (charter duplication) and Bug N (_distilled_from provenance).
//!
//! Bug M: Exporting an estate that has seeded _charter system drawers must not
//! include them in the vault export. Importing that vault into a freshly-
//! provisioned target estate must not duplicate the charter drawers — the charter
//! count must stay at 7 (the provisioned set), not grow to 14.
//!
//! Bug N: A factoid with a `_distilled_from` provenance tunnel must export such
//! that the vault note body contains NO `_distilled_from` link text. After
//! import, the factoid drawer content must be clean, and the `_distilled_from`
//! tunnel must exist in the re-imported estate.
//!
//! Mirrors Swift `VaultBridgeTests`:
//!   - `exportExcludesCharterDrawers()`
//!   - `distilledFromProvenanceRoundTrips()`

use std::{path::PathBuf, sync::Arc};

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::{
    coordinator::{EstateCoordinator, EstateKind, EstateProvisionParams, SyncMode},
    handle::EstateHandle,
};
use locus_kit::{
    default_wings::{CHARTER_ROOM, DEFAULT_WINGS},
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, TunnelCaptureFrame},
    tunnel_operational::{TunnelKind, TunnelOriginClass},
};
use persistence_kit::{inmemory::InMemoryStorage, storage::Storage};
use uuid::Uuid;
use vault_kit::{DrawerMapping, ObsidianAdapter, VaultAdapter, VaultBridge, VaultExportScope};

/// Fixed timestamp in milliseconds-since-epoch for determinism.
const NOW: i64 = 1_750_000_000_000;

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

/// Create the (DrawerStore, Storage) pair needed by `provision`.
/// The same `InMemoryStorage` backs both the LocusKit store and the GLK sub-stores.
fn make_stores() -> (Arc<dyn DrawerStore>, Arc<dyn Storage>) {
    let storage: Arc<InMemoryStorage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None)
            .expect("InMemoryDrawerStore::with_storage"),
    );
    (store as Arc<dyn DrawerStore>, storage as Arc<dyn Storage>)
}

/// Standard GLK provision params — LocusOnly so no Corpus/VectorStore sub-stores
/// are needed (charter seeding only requires the DrawerStore).
fn glk_params(name: &str) -> EstateProvisionParams {
    EstateProvisionParams {
        estate_name: name.to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 0,
        zoom_window_high: 999,
        framework_profile: "Test".to_string(),
        sync_mode: SyncMode::None,
    }
}

/// Provision a GLK estate — seeds 7 default wings each with a `_charter` drawer.
fn provision_estate(name: &str) -> (EstateCoordinator, EstateHandle) {
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            store,
            storage,
            None,
            OwnerCredentials::new(name),
            glk_params(name),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision");
    (coord, handle)
}

/// Open a simple (non-provisioned) in-memory estate. No charter seeding.
fn open_simple(name: &str) -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"),
    );
    let handle = coord
        .open(store, OwnerCredentials::new(name), 0, 999)
        .expect("open");
    (coord, handle)
}

/// Build a VaultBridge over the given coordinator (mutable borrow, matching the
/// existing test helper convention in `wing_vault_layout.rs` and `idempotent_import.rs`).
fn bridge(coord: &mut EstateCoordinator) -> VaultBridge<'_> {
    VaultBridge::new(
        coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::new("charter-prov-test", "test-v1", false),
    )
}

/// Recall currently-believed drawers (all confirmation states, all trust levels).
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

/// Temp vault directory path.
fn temp_vault(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!("vaultkit-charter-prov-{}-{}", tag, Uuid::new_v4()))
}

// ─────────────────────────────────────────────────────────────────
// Bug M: charter exclusion from export
// ─────────────────────────────────────────────────────────────────

/// Exporting a provisioned estate must NOT include `_charter` system drawers.
/// Importing that vault into a freshly-provisioned target must not add duplicate
/// charters — the charter count must remain 7 (the provisioned set), not rise to 14.
///
/// Root cause: the export path previously included `room == "_charter"` drawers.
/// Fix: `DrawerMapping::export` now skips drawers whose `room == CHARTER_ROOM`.
///
/// Mirrors Swift `VaultBridgeTests.exportExcludesCharterDrawers`.
#[test]
fn export_excludes_charter_drawers_no_duplicates_on_import() {
    let expected_wing_count = DEFAULT_WINGS.len(); // 7

    // --- Source estate: provisioned so 7 charter drawers are seeded. ---
    let (coord1, handle1) = provision_estate("charter-source");

    // Capture one user-content drawer so the export has something to write.
    let user_frame = CaptureFrame::new(
        "A regular user note for charter exclusion test.",
        CaptureChannel::Typed,
        "notes",
        LatticeAnchor::udc("000"),
        "charter-prov-test",
        "test-v1",
    );
    coord1
        .capture(&handle1, user_frame, NOW)
        .expect("capture user note");

    // Export: mapping.export() produces a projection; adapter writes the vault.
    let vault = temp_vault("bug-m");
    std::fs::create_dir_all(&vault).expect("create vault dir");
    let mapping = DrawerMapping::new("charter-prov-test", "test-v1", false);
    let projection = mapping
        .export(&coord1, &handle1, NOW, VaultExportScope::Believed)
        .expect("mapping.export");

    // The projection must contain only 1 note (the user note, NOT the 7 charters).
    assert_eq!(
        projection.notes.len(),
        1,
        "Bug M: export projection must contain only the 1 user-content note, not the {} charter drawers",
        expected_wing_count
    );

    // Write the vault to disk so we can import it.
    let adapter = ObsidianAdapter::new();
    adapter
        .from_ir(&projection.notes, &vault)
        .expect("adapter.from_ir");

    // Verify no _charter files or folders were written to the vault.
    let vault_entries = walkdir_all(&vault);
    let charter_entries: Vec<&PathBuf> = vault_entries
        .iter()
        .filter(|p| p.components().any(|c| c.as_os_str() == "_charter"))
        .collect();
    assert!(
        charter_entries.is_empty(),
        "Bug M: vault must contain no _charter folder or files; found: {:?}",
        charter_entries
    );

    // --- Target estate: provisioned with its own 7 charter drawers. ---
    let (mut coord2, handle2) = provision_estate("charter-target");

    // Verify the target has exactly 7 charter drawers before import.
    // Charter drawers are visible via Estate::all_drawers() — the recall
    // pipeline excludes them, so we must go through the estate directly.
    let estate2 = coord2.estate_for(&handle2).expect("estate_for");
    let all_before = estate2.all_drawers().expect("all_drawers before import");
    let charters_before: Vec<_> = all_before.iter().filter(|d| d.room == CHARTER_ROOM).collect();
    assert_eq!(
        charters_before.len(),
        expected_wing_count,
        "Bug M: provisioned target must have {} charter drawers before import",
        expected_wing_count
    );

    // Import the vault into the target estate.
    let import_report = bridge(&mut coord2)
        .import_vault(&vault, &handle2, NOW)
        .expect("import_vault");
    assert_eq!(
        import_report.drawers_written, 1,
        "Bug M: import must write exactly the 1 user-content note, not the charter drawers"
    );

    // Charter count must be unchanged — still 7, not 14.
    let estate2_post = coord2.estate_for(&handle2).expect("estate_for post-import");
    let all_after = estate2_post.all_drawers().expect("all_drawers after import");
    let charters_after: Vec<_> = all_after.iter().filter(|d| d.room == CHARTER_ROOM).collect();
    assert_eq!(
        charters_after.len(),
        expected_wing_count,
        "Bug M: charter count must remain {} after import — no duplicates from vault",
        expected_wing_count
    );

    // Cleanup.
    let _ = std::fs::remove_dir_all(&vault);
}

// ─────────────────────────────────────────────────────────────────
// Bug N: _distilled_from provenance as tunnel not body text
// ─────────────────────────────────────────────────────────────────

/// A factoid with a `_distilled_from` provenance tunnel must round-trip
/// export → import such that:
///   1. The exported vault note body does NOT contain `_distilled_from` text.
///   2. After import, the factoid drawer content is clean (matches original).
///   3. The `_distilled_from` tunnel exists in the re-imported estate.
///
/// Root cause: `_distilled_from` tunnels were previously included in `note.links`,
/// causing the Obsidian adapter to render them as markdown links appended to the
/// note body, corrupting the factoid content on re-import.
///
/// Fix: `DrawerMapping::note_ir_from` separates provenance tunnels into a
/// `distilled_from_sources` frontmatter key; the import path reconstructs them
/// as real tunnels without touching the content field.
///
/// Mirrors Swift `VaultBridgeTests.distilledFromProvenanceRoundTrips`.
#[test]
fn distilled_from_provenance_round_trips_as_tunnel_not_body_text() {
    // --- Source estate: plain open (no provision; charter seeding not needed). ---
    let (coord1, handle1) = open_simple("distilled-source");

    let factoid_content = "Distilled factoid: the essence of the source.".to_owned();

    // Capture the source memory drawer.
    let source_frame = CaptureFrame::new(
        "Original source memory content.",
        CaptureChannel::Typed,
        "raw-memories",
        LatticeAnchor::udc("000"),
        "charter-prov-test",
        "test-v1",
    );
    let source_drawer = coord1
        .capture(&handle1, source_frame, NOW)
        .expect("capture source drawer");

    // Capture the factoid drawer in "_distilled" (simulates DistillationCycle output).
    let factoid_frame = CaptureFrame::new(
        factoid_content.as_str(),
        CaptureChannel::Typed,
        "_distilled",
        LatticeAnchor::udc("001"),
        "distillation-daemon",
        "test-v1",
    );
    let factoid_drawer = coord1
        .capture(&handle1, factoid_frame, NOW)
        .expect("capture factoid drawer");

    // Create the `_distilled_from` provenance tunnel (factoid → source),
    // exactly as DistillationCycle does.
    let estate1 = coord1.estate_for(&handle1).expect("estate_for source");
    let mut provenance_frame = TunnelCaptureFrame::new(
        factoid_drawer.wing.clone(),
        "_distilled".to_owned(),
        source_drawer.wing.clone(),
        source_drawer.room.clone(),
        "_distilled_from".to_owned(),
        "distillation-daemon".to_owned(),
    );
    provenance_frame.source_drawer_id = Some(factoid_drawer.id.clone());
    provenance_frame.target_drawer_id = Some(source_drawer.id.clone());
    provenance_frame.kind = TunnelKind::References;
    provenance_frame.origin_class = TunnelOriginClass::Derived;
    estate1
        .capture_tunnel(provenance_frame, NOW)
        .expect("capture provenance tunnel");

    // Export the estate to the vault.
    let vault = temp_vault("bug-n");
    std::fs::create_dir_all(&vault).expect("create vault dir");
    let mapping = DrawerMapping::new("charter-prov-test", "test-v1", false);
    let projection = mapping
        .export(&coord1, &handle1, NOW, VaultExportScope::Believed)
        .expect("mapping.export");
    let adapter = ObsidianAdapter::new();
    adapter
        .from_ir(&projection.notes, &vault)
        .expect("adapter.from_ir");

    // --- Assertion 1: factoid vault file must NOT contain `_distilled_from` text. ---
    // Find the vault file under the _distilled/ room folder.
    let all_vault_files = walkdir_md(&vault);
    let factoid_path = all_vault_files
        .iter()
        .find(|p| p.components().any(|c| c.as_os_str() == "_distilled"))
        .expect("factoid vault file must exist under _distilled/ room folder");
    let factoid_text =
        std::fs::read_to_string(factoid_path).expect("read factoid vault file");

    assert!(
        !factoid_text.contains("_distilled_from"),
        "Bug N: factoid vault body must NOT contain '_distilled_from' link text; got:\n{}",
        factoid_text
    );
    // The frontmatter must carry the provenance metadata for round-trip reconstruction.
    assert!(
        factoid_text.contains("distilled_from_sources"),
        "Bug N: factoid vault file must carry 'distilled_from_sources' frontmatter key; got:\n{}",
        factoid_text
    );

    // --- Assertion 2: import into a fresh estate; factoid content must be clean. ---
    let (mut coord2, handle2) = open_simple("distilled-target");
    let import_report = bridge(&mut coord2)
        .import_vault(&vault, &handle2, NOW)
        .expect("import_vault");
    // Both the source drawer and the factoid drawer must be imported.
    assert!(
        import_report.drawers_written >= 1,
        "Bug N: at least the factoid drawer must be imported; drawers_written={}",
        import_report.drawers_written
    );

    let imported = current_drawers(&coord2, &handle2);
    let imported_factoid = imported.iter().find(|d| d.room == "_distilled");
    let factoid = imported_factoid.expect("factoid drawer must be imported");

    assert_eq!(
        factoid.content, factoid_content,
        "Bug N: factoid content must be clean after round-trip — no '_distilled_from' link appended"
    );
    assert!(
        !factoid.content.contains("_distilled_from"),
        "Bug N: factoid content must not contain the provenance link text; got: {:?}",
        factoid.content
    );

    // --- Assertion 3: `_distilled_from` tunnel must exist after import. ---
    // Use Estate::tunnels_from_wing — the only surface that returns tunnels
    // originating from a specific wing without going through the recall pipeline.
    let estate2 = coord2.estate_for(&handle2).expect("estate_for target");
    let tunnels = estate2
        .tunnels_from_wing(&factoid.wing)
        .expect("tunnels_from_wing");
    let provenance_tunnels: Vec<_> = tunnels
        .iter()
        .filter(|t| t.label == "_distilled_from" && t.source_room == "_distilled")
        .collect();
    assert!(
        !provenance_tunnels.is_empty(),
        "Bug N: _distilled_from provenance tunnel must exist after round-trip import"
    );
    let p_tunnel = &provenance_tunnels[0];
    assert_eq!(
        p_tunnel.target_room, source_drawer.room,
        "Bug N: provenance tunnel must point to the source drawer's room ('{}'); got '{}'",
        source_drawer.room, p_tunnel.target_room
    );

    // Cleanup.
    let _ = std::fs::remove_dir_all(&vault);
}

// ─────────────────────────────────────────────────────────────────
// Filesystem helpers
// ─────────────────────────────────────────────────────────────────

/// Walk all paths under `dir` recursively (files only).
fn walkdir_all(dir: &PathBuf) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                out.extend(walkdir_all(&p));
            } else {
                out.push(p);
            }
        }
    }
    out
}

/// Walk all `.md` files under `dir` recursively.
fn walkdir_md(dir: &PathBuf) -> Vec<PathBuf> {
    walkdir_all(dir)
        .into_iter()
        .filter(|p| p.extension().map_or(false, |e| e == "md"))
        .collect()
}
