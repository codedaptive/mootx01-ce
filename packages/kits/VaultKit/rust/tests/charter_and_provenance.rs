//! Tests for hint-drawer export behaviour, Bug N (_distilled_from provenance),
//! and CAND-EXP-PROV (provenance tunnel target privacy).
//!
//! Hint-drawer export: hint drawers (AI_Charter_Hint room) are normal drawers —
//! they export and import like any other drawer. A provisioned estate with 7 hint
//! drawers + 1 user note exports 8 notes; the AI_Charter_Hint room folder appears
//! in the vault tree; importing into a fresh estate writes all 8 drawers.
//!
//! Bug N: A factoid with a `_distilled_from` provenance tunnel must export such
//! that the vault note body contains NO `_distilled_from` link text. After
//! import, the factoid drawer content must be clean, and the `_distilled_from`
//! tunnel must exist in the re-imported estate.
//!
//! CAND-EXP-PROV: provenance tunnel targets are filtered by export scope so a
//! normal exported factoid cannot leak the wing/room of a secret or
//! restricted-under-default-scope source drawer via `distilled_from_sources`
//! frontmatter. Three tests:
//!   - `provenance_tunnel_to_secret_drawer_excluded_from_frontmatter`
//!   - `provenance_tunnel_to_restricted_drawer_scope_gated`
//!   - `provenance_tunnel_to_normal_drawer_always_included`
//!
//! Mirrors Swift `VaultBridgeTests` / `PrivacyTierAndReceiptTests`:
//!   - `exportIncludesHintDrawers()`
//!   - `distilledFromProvenanceRoundTrips()`
//!   - `provenanceTunnelToSecretDrawerExcluded()`
//!   - `provenanceTunnelToRestrictedDrawerScopeGated()`
//!   - `provenanceTunnelToNormalDrawerAlwaysIncluded()`

use std::{path::PathBuf, sync::Arc};

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::{
    coordinator::{EstateCoordinator, EstateKind, EstateProvisionParams, SyncMode},
    handle::EstateHandle,
};
use locus_kit::{
    default_wings::{HINT_ROOM, DEFAULT_WINGS},
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
use vault_kit::drawer_mapping::resolve_drawer_node_names;

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

/// Standard GLK provision params.
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

/// Provision a GLK estate — seeds 7 default wings each with an AI_Charter_Hint drawer.
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

/// Open a simple (non-provisioned) in-memory estate. No hint seeding.
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

/// Build a VaultBridge over the given coordinator.
fn bridge(coord: &mut EstateCoordinator) -> VaultBridge<'_> {
    VaultBridge::new(
        coord,
        Box::new(ObsidianAdapter::new()),
        DrawerMapping::new("hint-prov-test", "test-v1", false),
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
    std::env::temp_dir().join(format!("vaultkit-hint-prov-{}-{}", tag, Uuid::new_v4()))
}

// ─────────────────────────────────────────────────────────────────
// Hint-drawer export: hint drawers ARE included in vault export
// ─────────────────────────────────────────────────────────────────

/// Hint drawers (AI_Charter_Hint room) are normal drawers — they export to the
/// vault alongside user-content drawers. A provisioned estate with 7 hint drawers
/// + 1 user note must export exactly 8 NoteIR entries. The AI_Charter_Hint
/// folder must appear in the vault tree. Importing into a fresh estate writes
/// all 8 drawers.
///
/// Mirrors Swift `VaultBridgeTests.exportIncludesHintDrawers`.
#[test]
fn export_includes_hint_drawers_as_normal_entries() {
    let expected_wing_count = DEFAULT_WINGS.len(); // 7
    let expected_total = expected_wing_count + 1;  // 7 hints + 1 user note

    // --- Source estate: provisioned so 7 hint drawers are seeded. ---
    let (coord1, handle1) = provision_estate("hint-source");

    // Capture one user-content drawer alongside the 7 hint drawers.
    let user_frame = CaptureFrame::new(
        "A regular user note for hint-export test.",
        CaptureChannel::Typed,
        "notes",
        LatticeAnchor::udc("000"),
        "hint-prov-test",
        "test-v1",
    );
    coord1
        .capture(&handle1, user_frame, NOW)
        .expect("capture user note");

    // Export: all believed drawers including hints.
    let vault = temp_vault("hint-export");
    std::fs::create_dir_all(&vault).expect("create vault dir");
    let mapping = DrawerMapping::new("hint-prov-test", "test-v1", false);
    let projection = mapping
        .export(&coord1, &handle1, NOW, VaultExportScope::Believed)
        .expect("mapping.export");

    // All 8 drawers (7 hints + 1 user note) must be in the projection.
    assert_eq!(
        projection.notes.len(),
        expected_total,
        "hint-export: projection must contain {} entries (7 hint drawers + 1 user note); got {}",
        expected_total,
        projection.notes.len()
    );

    // Write vault to disk via ObsidianAdapter.
    let adapter = ObsidianAdapter::new();
    adapter
        .from_ir(&projection.notes, &vault)
        .expect("adapter.from_ir");

    // The AI_Charter_Hint room folder must appear in the vault tree (hint drawers
    // are normal — they export under their wing/<room>/<slug>.md path).
    let vault_entries = walkdir_all(&vault);
    let hint_entries: Vec<&PathBuf> = vault_entries
        .iter()
        .filter(|p| p.components().any(|c| c.as_os_str() == HINT_ROOM))
        .collect();
    assert!(
        !hint_entries.is_empty(),
        "hint-export: vault must contain AI_Charter_Hint folder/files (hint drawers export normally); found entries: {:?}",
        walkdir_all(&vault)
    );

    // --- Import vault into a fresh (non-provisioned) estate. ---
    let (mut coord2, handle2) = open_simple("hint-target");
    let import_report = bridge(&mut coord2)
        .import_vault(&vault, &handle2, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import_vault");

    // All 8 drawers must be written (hints are not filtered on import either).
    assert_eq!(
        import_report.drawers_written,
        expected_total,
        "hint-import: all {} drawers (7 hints + 1 user note) must be written into the fresh estate",
        expected_total
    );

    // Hint drawers must be in recall (they are normal drawers).
    let recalled = current_drawers(&coord2, &handle2);
    let names = resolve_drawer_node_names(&coord2, &handle2, &recalled);
    let hint_recalled: Vec<_> = recalled
        .iter()
        .filter(|d| names.get(&d.parent_node_id).map(|(_, r)| r.as_str()) == Some(HINT_ROOM))
        .collect();
    assert_eq!(
        hint_recalled.len(),
        expected_wing_count,
        "hint-import: {} hint drawers must appear in recall (normal drawers); got {}",
        expected_wing_count,
        hint_recalled.len()
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
    // --- Source estate: plain open (no provision; hint seeding not needed). ---
    let (coord1, handle1) = open_simple("distilled-source");

    let factoid_content = "Distilled factoid: the essence of the source.".to_owned();

    // Capture the source memory drawer.
    let source_frame = CaptureFrame::new(
        "Original source memory content.",
        CaptureChannel::Typed,
        "raw-memories",
        LatticeAnchor::udc("000"),
        "hint-prov-test",
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
    // Resolve wing/room display names from the node tree.
    let both_drawers = vec![factoid_drawer.clone(), source_drawer.clone()];
    let node_names = resolve_drawer_node_names(&coord1, &handle1, &both_drawers);
    let (factoid_wing, _) = node_names.get(&factoid_drawer.parent_node_id).cloned().unwrap_or_default();
    let (source_wing, source_room) = node_names.get(&source_drawer.parent_node_id).cloned().unwrap_or_default();

    let estate1 = coord1.estate_for(&handle1).expect("estate_for source");
    let mut provenance_frame = TunnelCaptureFrame::new(
        factoid_wing.clone(),
        "_distilled".to_owned(),
        source_wing.clone(),
        source_room.clone(),
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
    let mapping = DrawerMapping::new("hint-prov-test", "test-v1", false);
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
        .import_vault(&vault, &handle2, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import_vault");
    // Both the source drawer and the factoid drawer must be imported.
    assert!(
        import_report.drawers_written >= 1,
        "Bug N: at least the factoid drawer must be imported; drawers_written={}",
        import_report.drawers_written
    );

    let imported = current_drawers(&coord2, &handle2);
    let imported_names = resolve_drawer_node_names(&coord2, &handle2, &imported);
    let imported_factoid = imported.iter().find(|d| {
        imported_names.get(&d.parent_node_id).map(|(_, r)| r.as_str()) == Some("_distilled")
    });
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
    // Resolve the factoid's wing name from the node tree.
    let (factoid_wing_imported, _) = imported_names.get(&factoid.parent_node_id).cloned().unwrap_or_default();
    let estate2 = coord2.estate_for(&handle2).expect("estate_for target");
    let tunnels = estate2
        .tunnels_from_wing(&factoid_wing_imported)
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
        p_tunnel.target_room, source_room,
        "Bug N: provenance tunnel must point to the source drawer's room ('{}'); got '{}'",
        source_room, p_tunnel.target_room
    );

    // Cleanup.
    let _ = std::fs::remove_dir_all(&vault);
}

// ─────────────────────────────────────────────────────────────────
// CAND-EXP-PROV: provenance tunnel target privacy
// ─────────────────────────────────────────────────────────────────

/// Helper: capture a `_distilled_from` provenance tunnel from a factoid
/// drawer to a source drawer, exactly as DistillationCycle does.
fn capture_provenance_tunnel(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    factoid_id: &str,
    factoid_wing: &str,
    factoid_room: &str,
    source_id: &str,
    source_wing: &str,
    source_room: &str,
) {
    let estate = coord.estate_for(handle).expect("estate_for");
    let mut frame = TunnelCaptureFrame::new(
        factoid_wing.to_owned(),
        factoid_room.to_owned(),
        source_wing.to_owned(),
        source_room.to_owned(),
        "_distilled_from".to_owned(),
        "test".to_owned(),
    );
    frame.source_drawer_id = Some(factoid_id.to_owned());
    frame.target_drawer_id = Some(source_id.to_owned());
    frame.kind = TunnelKind::References;
    frame.origin_class = TunnelOriginClass::Derived;
    estate.capture_tunnel(frame, NOW).expect("capture provenance tunnel");
}

/// All `.md` text under a vault, concatenated (shared helper for prov tests).
fn prov_all_markdown(vault: &PathBuf) -> String {
    walkdir_md(vault)
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .collect::<Vec<_>>()
        .join("\n")
}

/// CAND-EXP-PROV: A factoid with a `_distilled_from` tunnel to a SECRET source
/// drawer must NOT include the secret drawer's wing/room in `distilled_from_sources`
/// frontmatter. Secret drawers are excluded from bulk export;
/// writing their location into frontmatter leaks it to any vault reader.
///
/// Mirrors Swift `PrivacyTierAndReceiptTests.provenanceTunnelToSecretDrawerExcluded`.
#[test]
fn provenance_tunnel_to_secret_drawer_excluded_from_frontmatter() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let (coord, handle) = open_simple("prov-secret");

    // Capture a SECRET source drawer. Its wing/room must never appear in export output.
    let mut secret_frame = CaptureFrame::new(
        "Sensitive therapy session notes.",
        CaptureChannel::Typed,
        "Personal",                     // the location that must not leak
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    secret_frame.sensitivity = AdjectiveSensitivity::Secret;
    let secret_drawer = coord.capture(&handle, secret_frame, NOW).expect("capture secret");

    // Capture a normal factoid that was distilled FROM the secret source.
    let factoid_frame = CaptureFrame::new(
        "Distilled insight from private notes.",
        CaptureChannel::Typed,
        "factoids",
        LatticeAnchor::udc("001"),
        "distillation-daemon",
        "test-v1",
    );
    let factoid_drawer = coord.capture(&handle, factoid_frame, NOW).expect("capture factoid");

    // Resolve display names.
    let both = vec![secret_drawer.clone(), factoid_drawer.clone()];
    let names = resolve_drawer_node_names(&coord, &handle, &both);
    let (secret_wing, _) = names.get(&secret_drawer.parent_node_id).cloned().unwrap_or_default();
    let (factoid_wing, _) = names.get(&factoid_drawer.parent_node_id).cloned().unwrap_or_default();

    // Wire the _distilled_from provenance tunnel: factoid → secret source.
    capture_provenance_tunnel(
        &coord, &handle,
        &factoid_drawer.id, &factoid_wing, "factoids",
        &secret_drawer.id, &secret_wing, "Personal",
    );

    // Export under the default scope (Believed). Secret drawers are excluded.
    let vault = temp_vault("prov-secret");
    std::fs::create_dir_all(&vault).expect("mkdir");
    let mapping = DrawerMapping::new("test", "test-v1", false);
    let projection = mapping
        .export(&coord, &handle, NOW, VaultExportScope::Believed)
        .expect("export");
    let adapter = ObsidianAdapter::new();
    adapter.from_ir(&projection.notes, &vault).expect("from_ir");

    let all_md = prov_all_markdown(&vault);

    // The secret source content must not appear in the vault.
    assert!(
        !all_md.contains("Sensitive therapy session notes."),
        "secret drawer content must never appear in export"
    );

    // The factoid must be exported (it is Normal tier).
    assert!(
        all_md.contains("Distilled insight from private notes."),
        "factoid must appear in export (Normal tier)"
    );

    // CAND-EXP-PROV: the secret source's wing/room must NOT appear in distilled_from_sources.
    // If the fix is absent, the frontmatter contains "<defaultWing>/Personal" — leaking the
    // existence and location of the secret drawer.
    let secret_location = format!("{}/Personal", secret_wing);
    assert!(
        !all_md.contains(&secret_location),
        "CAND-EXP-PROV: secret source location '{}' must not appear in exported frontmatter; got:\n{}",
        secret_location,
        all_md
    );

    let _ = std::fs::remove_dir_all(&vault);
}

/// CAND-EXP-PROV: A factoid with a `_distilled_from` tunnel to a RESTRICTED
/// (private-tier) source drawer must NOT include the restricted drawer's location
/// under the DEFAULT scope, but MUST include it under `BelievedIncludingPrivate`.
///
/// Mirrors Swift `PrivacyTierAndReceiptTests.provenanceTunnelToRestrictedDrawerScopeGated`.
#[test]
fn provenance_tunnel_to_restricted_drawer_scope_gated() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let (coord, handle) = open_simple("prov-restricted");

    // Capture a RESTRICTED source drawer.
    let mut restricted_frame = CaptureFrame::new(
        "Private journal entry.",
        CaptureChannel::Typed,
        "journal",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    restricted_frame.sensitivity = AdjectiveSensitivity::Restricted;
    let restricted_drawer = coord.capture(&handle, restricted_frame, NOW).expect("capture restricted");

    // Capture a normal factoid distilled from the restricted source.
    let factoid_frame = CaptureFrame::new(
        "Synthesized insight from private journal.",
        CaptureChannel::Typed,
        "factoids",
        LatticeAnchor::udc("001"),
        "distillation-daemon",
        "test-v1",
    );
    let factoid_drawer = coord.capture(&handle, factoid_frame, NOW).expect("capture factoid");

    let both = vec![restricted_drawer.clone(), factoid_drawer.clone()];
    let names = resolve_drawer_node_names(&coord, &handle, &both);
    let (restricted_wing, _) = names.get(&restricted_drawer.parent_node_id).cloned().unwrap_or_default();
    let (factoid_wing, _) = names.get(&factoid_drawer.parent_node_id).cloned().unwrap_or_default();

    capture_provenance_tunnel(
        &coord, &handle,
        &factoid_drawer.id, &factoid_wing, "factoids",
        &restricted_drawer.id, &restricted_wing, "journal",
    );

    let restricted_location = format!("{}/journal", restricted_wing);
    let mapping = DrawerMapping::new("test", "test-v1", false);
    let adapter = ObsidianAdapter::new();

    // --- Default scope: restricted source location must NOT appear in frontmatter ---
    let vault_default = temp_vault("prov-restricted-default");
    std::fs::create_dir_all(&vault_default).expect("mkdir default");
    let proj_default = mapping
        .export(&coord, &handle, NOW, VaultExportScope::Believed)
        .expect("export default");
    adapter.from_ir(&proj_default.notes, &vault_default).expect("from_ir default");
    let md_default = prov_all_markdown(&vault_default);

    assert!(
        !md_default.contains(&restricted_location),
        "CAND-EXP-PROV: restricted source location '{}' must not appear in default-scope export; got:\n{}",
        restricted_location,
        md_default
    );
    let _ = std::fs::remove_dir_all(&vault_default);

    // --- Private scope: restricted source location MUST appear (opt-in includes it) ---
    let vault_private = temp_vault("prov-restricted-private");
    std::fs::create_dir_all(&vault_private).expect("mkdir private");
    let proj_private = mapping
        .export(&coord, &handle, NOW, VaultExportScope::BelievedIncludingPrivate)
        .expect("export private");
    adapter.from_ir(&proj_private.notes, &vault_private).expect("from_ir private");
    let md_private = prov_all_markdown(&vault_private);

    assert!(
        md_private.contains(&restricted_location),
        "CAND-EXP-PROV: restricted source location '{}' MUST appear in private-scope export; got:\n{}",
        restricted_location,
        md_private
    );
    let _ = std::fs::remove_dir_all(&vault_private);
}

/// CAND-EXP-PROV: A factoid with a `_distilled_from` tunnel to a NORMAL-tier source
/// drawer continues to include the source's wing/room in `distilled_from_sources` —
/// the fix must not break the existing round-trip for non-excluded targets.
///
/// Mirrors Swift `PrivacyTierAndReceiptTests.provenanceTunnelToNormalDrawerAlwaysIncluded`.
#[test]
fn provenance_tunnel_to_normal_drawer_always_included() {
    let (coord, handle) = open_simple("prov-normal");

    // Capture a Normal-tier source drawer.
    let normal_frame = CaptureFrame::new(
        "Plain public research note.",
        CaptureChannel::Typed,
        "research",
        LatticeAnchor::udc("000"),
        "owner",
        "test-v1",
    );
    let normal_drawer = coord.capture(&handle, normal_frame, NOW).expect("capture normal");

    // Capture a factoid that cites the normal source.
    let factoid_frame = CaptureFrame::new(
        "Summary of the research note.",
        CaptureChannel::Typed,
        "factoids",
        LatticeAnchor::udc("001"),
        "distillation-daemon",
        "test-v1",
    );
    let factoid_drawer = coord.capture(&handle, factoid_frame, NOW).expect("capture factoid");

    let both = vec![normal_drawer.clone(), factoid_drawer.clone()];
    let names = resolve_drawer_node_names(&coord, &handle, &both);
    let (normal_wing, _) = names.get(&normal_drawer.parent_node_id).cloned().unwrap_or_default();
    let (factoid_wing, _) = names.get(&factoid_drawer.parent_node_id).cloned().unwrap_or_default();

    capture_provenance_tunnel(
        &coord, &handle,
        &factoid_drawer.id, &factoid_wing, "factoids",
        &normal_drawer.id, &normal_wing, "research",
    );

    let vault = temp_vault("prov-normal");
    std::fs::create_dir_all(&vault).expect("mkdir");
    let mapping = DrawerMapping::new("test", "test-v1", false);
    let projection = mapping
        .export(&coord, &handle, NOW, VaultExportScope::Believed)
        .expect("export");
    let adapter = ObsidianAdapter::new();
    adapter.from_ir(&projection.notes, &vault).expect("from_ir");

    let all_md = prov_all_markdown(&vault);
    let normal_location = format!("{}/research", normal_wing);

    // The normal source's wing/room MUST appear in distilled_from_sources.
    assert!(
        all_md.contains("distilled_from_sources"),
        "factoid with normal provenance source must carry distilled_from_sources frontmatter key"
    );
    assert!(
        all_md.contains(&normal_location),
        "CAND-EXP-PROV: normal-tier source location '{}' must appear in distilled_from_sources; got:\n{}",
        normal_location,
        all_md
    );

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
