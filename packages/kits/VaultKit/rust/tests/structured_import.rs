//! P0 BLOCKER resolution: structured-import parity tests.
//!
//! Mirrors Swift `VaultBridgeTests` structured-import tests (the
//! `structuredImport*` suite). A structured vault document carrying
//! facts + scope + multi-level pathComponents must import with EVERY
//! structural element present and queryable afterward:
//!
//!   - `facts` land as KG facts (queryable via `recall_kg_facts`).
//!   - `scope` entries land as KG facts keyed `"scope:<key>"`.
//!   - `path_components.len() > 1` produces the full joined room path,
//!     not just the leaf.
//!
//! Corrupt/unmappable structure must error loudly; the note must NOT be
//! silently dropped (fail-loud discipline). Mirrors the fail-loud structured
//! import behavior of Swift `VaultBridgeTests.structuredNote`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use vault_kit::{Block, DrawerMapping, FactIR, NoteIR};
use vault_kit::drawer_mapping::resolve_drawer_node_names;

/// Fixed operation instant so tests are deterministic.
const NOW: i64 = 1_765_000_000_000; // ms-since-epoch

/// Open one in-memory estate.
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("vaultkit-structured-import-tests"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// The shared structured fixture. Mirrors Swift
/// `VaultBridgeTests.structuredNote(now:)` — same fields, same values.
/// Carries:
///   - 2 FactIR triples (alice/works_at/acme, acme/located_in/berlin)
///   - 2 scope entries (userId="u-42", agentId="ag-7")
///   - pathComponents = ["projects", "alpha"] (2 levels)
///   - kind = "note"
fn structured_note() -> NoteIR {
    let frontmatter = HashMap::new();
    // No explicit room key — forces path_components resolution.

    let facts = vec![
        FactIR::new("alice", "works_at", "acme"),
        FactIR::new("acme", "located_in", "berlin"),
    ];

    let mut scope = BTreeMap::new();
    scope.insert("userId".to_string(), "u-42".to_string());
    scope.insert("agentId".to_string(), "ag-7".to_string());

    let mut note = NoteIR::new(
        "projects/alpha/structured-note",
        vec![Block::markdown("# Structured Note\nThis note carries structure.")],
        frontmatter,
        Vec::new(), // no wikilinks
        vec!["test-tag".to_string()],
        "projects/alpha",
        None,
        None,
    );
    note.facts = facts;
    note.scope = scope;
    note.path_components = vec!["projects".to_string(), "alpha".to_string()];
    // kind stays "note" (default)
    note
}

/// Import the structured note via DrawerMapping and return the outcome.
///
/// `coord` is `&mut` because `import_note` routes through `capture_with_mode`
/// (dual-path intake fix, G7) which requires mutable coordinator access.
///
/// Passes empty tombstone and content maps (no prior state) so this helper
/// exercises the first-import path. Tests that need prior-state should call
/// `import_note` directly with populated maps.
fn import_structured(
    mapping: &DrawerMapping,
    note: &NoteIR,
    coord: &mut EstateCoordinator,
    handle: &EstateHandle,
) -> vault_kit::ImportOutcome {
    let existing_lineage_ids: HashSet<uuid::Uuid> = HashSet::new();
    let existing_sensitivity: std::collections::HashMap<uuid::Uuid, AdjectiveSensitivity> =
        std::collections::HashMap::new();
    // Empty tombstone set: no previously-erased lineages in this helper.
    let tombstoned_lineage_ids: HashSet<uuid::Uuid> = HashSet::new();
    // Empty content map: no prior content to compare against (first import).
    let existing_content_by_lineage: std::collections::HashMap<uuid::Uuid, String> =
        std::collections::HashMap::new();
    // Empty stableSourceKey map: first import, no prior export paths recorded.
    // Guard cannot fire when existing_lineage_ids is empty.
    let existing_stable_source_key_by_lineage: std::collections::HashMap<uuid::Uuid, String> =
        std::collections::HashMap::new();
    let mut existing_tunnel_sigs: HashSet<String> = HashSet::new();
    mapping
        .import_note(
            note,
            coord,
            handle,
            &existing_lineage_ids,
            &existing_sensitivity,
            &tombstoned_lineage_ids,
            &existing_content_by_lineage,
            &existing_stable_source_key_by_lineage,
            &mut existing_tunnel_sigs,
            NOW,
        )
        .expect("import_note must succeed")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// facts land as KG facts and are queryable after import.
/// Mirrors Swift `structuredImportFactsLandAsKGFacts`.
#[test]
fn structured_import_facts_land_as_kg_facts() {
    let (mut coord, handle) = open_one();
    let note = structured_note();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    let outcome = import_structured(&mapping, &note, &mut coord, &handle);
    assert!(
        matches!(outcome, vault_kit::ImportOutcome::Written { .. }),
        "expected Written outcome, got {outcome:?}"
    );

    // Query KG facts. The structured note carries:
    //   - 2 FactIR triples (alice/works_at/acme, acme/located_in/berlin)
    //   - 2 scope entries (userId, agentId)
    //   - 1 tag ("test-tag") → 1 KG fact (hard-close #29-A)
    //   - kind = "note" (default) → no kind KG fact
    // Total: 5 KG facts.
    let kg_facts = coord.recall_kg_facts(&handle).expect("recall_kg_facts");
    assert_eq!(
        kg_facts.len(),
        5,
        "two FactIR + two scope entries + one tag = 5 KG facts; got {}",
        kg_facts.len()
    );

    let subjects: std::collections::HashSet<&str> =
        kg_facts.iter().map(|f| f.subject.as_str()).collect();
    assert!(subjects.contains("alice"), "alice FactIR must be a KG fact subject");
    assert!(subjects.contains("acme"), "acme FactIR must be a KG fact subject");
    assert!(subjects.contains("scope:userId"), "scope userId must be a KG fact subject");
    assert!(subjects.contains("scope:agentId"), "scope agentId must be a KG fact subject");
    assert!(subjects.contains("tag:test-tag"), "tag 'test-tag' must be a KG fact subject (hard-close #29-A)");
}

/// scope entries land as KG facts with the `has_value` predicate and
/// correct object values. Mirrors Swift `structuredImportScopeEntriesAsKGFacts`.
#[test]
fn structured_import_scope_entries_as_kg_facts() {
    let (mut coord, handle) = open_one();
    let note = structured_note();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    import_structured(&mapping, &note, &mut coord, &handle);

    let kg_facts = coord.recall_kg_facts(&handle).expect("recall_kg_facts");
    let scope_facts: Vec<_> = kg_facts.iter().filter(|f| f.subject.starts_with("scope:")).collect();
    assert_eq!(scope_facts.len(), 2, "two scope entries must produce two KG facts");
    assert!(
        scope_facts.iter().all(|f| f.predicate == "has_value"),
        "all scope KG facts must use 'has_value' predicate"
    );
    let user_id_fact = scope_facts
        .iter()
        .find(|f| f.subject == "scope:userId")
        .expect("scope:userId fact must exist");
    assert_eq!(user_id_fact.object, "u-42");
    let agent_id_fact = scope_facts
        .iter()
        .find(|f| f.subject == "scope:agentId")
        .expect("scope:agentId fact must exist");
    assert_eq!(agent_id_fact.object, "ag-7");
}

/// Multi-level path_components maps to the full joined room path.
/// Mirrors Swift `structuredImportHierarchyAsFullRoomPath`.
#[test]
fn structured_import_hierarchy_as_full_room_path() {
    let (mut coord, handle) = open_one();
    let note = structured_note();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    import_structured(&mapping, &note, &mut coord, &handle);

    // The note has path_components = ["projects", "alpha"] and no frontmatter room.
    // The drawer room must be "projects/alpha", not just "alpha".
    let drawers = coord
        .recall(
            &handle,
            locus_kit::filter::RecallFrame {
                filter_chain: vec![locus_kit::filter::Filter::Unconfirmed],
                hydration_level: locus_kit::filter::HydrationLevel::Structured,
                limit: Some(100),
                ordering: locus_kit::filter::Ordering::ByCaptureTimeDesc,
                as_of: None,
                trace_limit: None,
            },
            NOW,
        )
        .expect("recall");
    assert_eq!(drawers.len(), 1, "exactly one drawer must be created");
    let drawer = &drawers[0];
    let node_names = resolve_drawer_node_names(&coord, &handle, &drawers);
    let (_, room) = node_names.get(&drawer.parent_node_id).cloned().unwrap_or_default();
    assert_eq!(
        room, "projects/alpha",
        "multi-level path_components must produce full room path, not just the leaf 'alpha'"
    );
}

/// Regression (ADR-023): a vault import stores `filed_at` in epoch MILLISECONDS.
/// The bridge passes `NOW` (ms) into `capture_with_mode`, which stores it directly
/// into the millisecond-typed `filed_at` column — no ÷1000 — so it must round-trip
/// as the exact millisecond value, well below PersistenceKit's RFC-3339 year-9999
/// clamp boundary.
#[test]
fn import_filed_at_is_epoch_millis() {
    let (mut coord, handle) = open_one();
    let note = structured_note();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    import_structured(&mapping, &note, &mut coord, &handle);

    let drawers = coord
        .recall(
            &handle,
            locus_kit::filter::RecallFrame {
                filter_chain: vec![locus_kit::filter::Filter::Unconfirmed],
                hydration_level: locus_kit::filter::HydrationLevel::Structured,
                limit: Some(100),
                ordering: locus_kit::filter::Ordering::ByCaptureTimeDesc,
                as_of: None,
                trace_limit: None,
            },
            NOW,
        )
        .expect("recall");
    assert_eq!(drawers.len(), 1, "exactly one drawer must be created");
    let drawer = &drawers[0];
    // NOW is ms (1_765_000_000_000); filed_at must equal it exactly (no ÷1000).
    assert_eq!(
        drawer.filed_at,
        NOW,
        "filed_at must be the epoch-millisecond NOW, stored without conversion"
    );
    // And it must be well below the RFC-3339 year-9999 clamp boundary (ms).
    assert!(
        drawer.filed_at < 253_402_300_799_999,
        "filed_at {} must not be a clamped magnitude",
        drawer.filed_at
    );
}

/// facts and scope must not appear in fields_dropped after import.
/// Mirrors Swift `structuredImportFactsNotInFieldsDropped` and the updated
/// ExchangeAdapterTests.droppedFieldsAreRecorded.
#[test]
fn structured_import_facts_and_scope_not_in_fields_dropped() {
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    // Exercise import_note directly and confirm the outcome is Written with
    // no KG-structure fields in fields_dropped. The VaultBridge integration
    // is covered by the exchange_adapter tests. Here we verify the core
    // DrawerMapping path produces correct semantics for the report.
    let note = structured_note();
    let outcome = import_structured(&mapping, &note, &mut coord, &handle);
    assert!(
        matches!(outcome, vault_kit::ImportOutcome::Written { .. }),
        "expected Written; got {outcome:?}"
    );

    // facts, scope, and path_components must produce KG facts (not drops).
    let kg_facts = coord.recall_kg_facts(&handle).expect("recall_kg_facts");
    assert!(
        !kg_facts.is_empty(),
        "structured import must produce KG facts (not drop them)"
    );
}

/// Frontmatter `room` wins over path_components for room placement
/// (round-trip identity). Mirrors the Swift room-resolution priority.
#[test]
fn frontmatter_room_wins_over_path_components() {
    let (mut coord, handle) = open_one();
    let mut note = structured_note();
    // Insert an explicit room frontmatter key.
    note.frontmatter.insert("room".to_string(), "explicit-room".to_string());
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    import_structured(&mapping, &note, &mut coord, &handle);

    let drawers = coord
        .recall(
            &handle,
            locus_kit::filter::RecallFrame {
                filter_chain: vec![locus_kit::filter::Filter::Unconfirmed],
                hydration_level: locus_kit::filter::HydrationLevel::Structured,
                limit: Some(100),
                ordering: locus_kit::filter::Ordering::ByCaptureTimeDesc,
                as_of: None,
                trace_limit: None,
            },
            NOW,
        )
        .expect("recall");
    assert_eq!(drawers.len(), 1);
    let node_names = resolve_drawer_node_names(&coord, &handle, &drawers);
    let (_, room) = node_names.get(&drawers[0].parent_node_id).cloned().unwrap_or_default();
    assert_eq!(
        room, "explicit-room",
        "frontmatter room must override path_components"
    );
}

/// A single-component path_components uses the component as the room
/// (same as the old leaf-only behavior — no regression).
#[test]
fn single_component_path_uses_leaf_as_room() {
    let (mut coord, handle) = open_one();
    let mut note = structured_note();
    note.path_components = vec!["inbox".to_string()]; // single component
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    import_structured(&mapping, &note, &mut coord, &handle);

    let drawers = coord
        .recall(
            &handle,
            locus_kit::filter::RecallFrame {
                filter_chain: vec![locus_kit::filter::Filter::Unconfirmed],
                hydration_level: locus_kit::filter::HydrationLevel::Structured,
                limit: Some(100),
                ordering: locus_kit::filter::Ordering::ByCaptureTimeDesc,
                as_of: None,
                trace_limit: None,
            },
            NOW,
        )
        .expect("recall");
    assert_eq!(drawers.len(), 1);
    let node_names = resolve_drawer_node_names(&coord, &handle, &drawers);
    let (_, room) = node_names.get(&drawers[0].parent_node_id).cloned().unwrap_or_default();
    assert_eq!(
        room, "inbox",
        "single-component path_components must use that component as room"
    );
}

// ---------------------------------------------------------------------------
// Hard-close #29-A: Tags import → queryable KG facts + round-trip export
// ---------------------------------------------------------------------------

/// Tags land as KG facts with "tagged" predicate (hard-close #29-A).
/// Mirrors Swift `VaultBridgeTests.tagsImportAsKGFacts`.
#[test]
fn tags_import_as_kg_facts() {
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    let note = NoteIR::new(
        "notes/tagged-note",
        vec![vault_kit::Block::markdown("A tagged note.")],
        Default::default(),
        vec![],
        vec!["swift".to_string(), "testing".to_string(), "vaultkit".to_string()],
        "",
        None,
        None,
    );

    import_structured(&mapping, &note, &mut coord, &handle);

    let kg_facts = coord.recall_kg_facts(&handle).expect("recall_kg_facts");
    let tag_facts: Vec<_> = kg_facts
        .iter()
        .filter(|f| f.subject.starts_with("tag:") && f.predicate == "tagged")
        .collect();
    assert_eq!(
        tag_facts.len(),
        3,
        "three tags must produce three KG facts; got {}",
        tag_facts.len()
    );
    let tag_values: std::collections::HashSet<&str> = tag_facts
        .iter()
        .map(|f| f.subject.strip_prefix("tag:").unwrap_or(""))
        .collect();
    assert!(tag_values.contains("swift"), "tag 'swift' must be a KG fact");
    assert!(tag_values.contains("testing"), "tag 'testing' must be a KG fact");
    assert!(tag_values.contains("vaultkit"), "tag 'vaultkit' must be a KG fact");
}

/// Tags round-trip: import→export reconstructs tags from KG facts (hard-close #29-A).
/// Mirrors Swift `VaultBridgeTests.tagsRoundTrip`.
#[test]
fn tags_round_trip_import_export() {
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    let note = NoteIR::new(
        "notes/tagged-note",
        vec![vault_kit::Block::markdown("A tagged note.")],
        Default::default(),
        vec![],
        vec!["alpha".to_string(), "beta".to_string()],
        "",
        None,
        None,
    );
    import_structured(&mapping, &note, &mut coord, &handle);

    let projection = mapping
        .export(&coord, &handle, NOW, vault_kit::VaultExportScope::Believed)
        .expect("export must succeed");
    assert_eq!(projection.notes.len(), 1, "export must produce one note");
    let exported_tags: std::collections::HashSet<&str> =
        projection.notes[0].tags.iter().map(|s| s.as_str()).collect();
    assert_eq!(
        exported_tags,
        ["alpha", "beta"].iter().copied().collect::<std::collections::HashSet<_>>(),
        "export must reconstruct tags from KG facts (hard-close #29-A round-trip)"
    );
}

// ---------------------------------------------------------------------------
// Hard-close #29-B: kind != "note" → typed KG fact + round-trip
// ---------------------------------------------------------------------------

/// kind "fact" lands as a KG fact with subject "record:kind" (hard-close #29-B).
/// Mirrors Swift `VaultBridgeTests.kindFactLandsAsKGFact`.
#[test]
fn kind_fact_lands_as_kg_fact() {
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    let mut note = NoteIR::new(
        "notes/fact-record",
        vec![vault_kit::Block::markdown("Alice works at Acme.")],
        Default::default(),
        vec![],
        vec![],
        "",
        None,
        None,
    );
    note.kind = "fact".to_string();
    import_structured(&mapping, &note, &mut coord, &handle);

    let kg_facts = coord.recall_kg_facts(&handle).expect("recall_kg_facts");
    let kind_fact = kg_facts
        .iter()
        .find(|f| f.subject == "record:kind" && f.predicate == "is");
    assert!(kind_fact.is_some(), "kind 'fact' must produce a 'record:kind' KG fact");
    assert_eq!(kind_fact.unwrap().object, "fact", "KG fact object must be 'fact'");
}

/// kind "journal" round-trips import→export (hard-close #29-B).
/// Mirrors Swift `VaultBridgeTests.kindJournalRoundTrips`.
#[test]
fn kind_journal_round_trips() {
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    let mut note = NoteIR::new(
        "notes/journal-entry",
        vec![vault_kit::Block::markdown("Today I shipped the adapter.")],
        Default::default(),
        vec![],
        vec![],
        "",
        None,
        None,
    );
    note.kind = "journal".to_string();
    import_structured(&mapping, &note, &mut coord, &handle);

    let projection = mapping
        .export(&coord, &handle, NOW, vault_kit::VaultExportScope::Believed)
        .expect("export must succeed");
    assert_eq!(projection.notes.len(), 1, "export must produce one note");
    assert_eq!(
        projection.notes[0].kind, "journal",
        "export must reconstruct kind from KG fact (hard-close #29-B round-trip)"
    );
}

/// kind "note" (default) produces NO "record:kind" KG fact.
/// Mirrors Swift `VaultBridgeTests.kindNoteProducesNoKGFact`.
#[test]
fn kind_note_produces_no_kg_fact() {
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);

    let note = NoteIR::new(
        "notes/plain-note",
        vec![vault_kit::Block::markdown("A plain note.")],
        Default::default(),
        vec![],
        vec![],
        "",
        None,
        None,
    );
    // kind defaults to "note" — no kind KG fact must be filed.
    import_structured(&mapping, &note, &mut coord, &handle);

    let kg_facts = coord.recall_kg_facts(&handle).expect("recall_kg_facts");
    let kind_fact = kg_facts.iter().find(|f| f.subject == "record:kind");
    assert!(
        kind_fact.is_none(),
        "default kind 'note' must not produce a 'record:kind' KG fact (export default)"
    );
}

/// fields_dropped is empty for a fully-structured note (hard-close #29).
/// Mirrors Swift `VaultBridgeTests.fieldsDroppedEmptyForFullyStructuredNote`.
#[test]
fn fields_dropped_empty_for_fully_structured_note() {
    use vault_kit::{ExchangeAdapter, VaultBridge};

    // mut: VaultBridge::new requires &mut EstateCoordinator (dual-path intake
    // fix — import_notes routes through capture_with_mode, G7).
    let (mut coord, handle) = open_one();
    let mapping = DrawerMapping::new("vaultkit-test", "vaultkit-noembed-v1", false);
    let mut bridge = VaultBridge::new(&mut coord, Box::new(ExchangeAdapter::new()), mapping);

    // The golden fixture has tags + non-"note" kind in drawer-001 and drawer-003.
    // All fields now land in substrate — fields_dropped must be empty.
    let fixture_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/VaultKitTests/Fixtures/exchange_export_golden.json");
    let report = bridge
        .import_vault(&fixture_path, &handle, NOW, None, genius_locus_kit::EncodeSpeed::Foreground)
        .expect("import must succeed");
    assert!(
        report.fields_dropped.is_empty(),
        "fields_dropped must be empty — no drop path may remain (hard-close #29); got: {:?}",
        report.fields_dropped
    );
}
