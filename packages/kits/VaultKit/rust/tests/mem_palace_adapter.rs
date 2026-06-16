//! MemPalaceChromaAdapter conformance tests.
//!
//! Loads the SAME fixture palace the Swift suite
//! (`Tests/VaultKitTests/MemPalaceChromaAdapterTests.swift`) exercises —
//! `Tests/VaultKitTests/Fixtures/mempalace/` (chroma.sqlite3 +
//! tunnels.json + knowledge_graph.sqlite3; regenerate with
//! `generate_fixture.sh`) — and asserts the SAME values: the
//! cross-language field-mapping conformance contract. Any change to the
//! fixture or the mapping must keep both suites green in the same commit.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use vault_kit::mem_palace_chroma_adapter::canonical_iso8601_from_mem_palace;
use vault_kit::{
    Block, DrawerMapping, FactIR, MemPalaceChromaAdapter, NoteIR, ObsidianAdapter, SourceRef,
    VaultAdapter, VaultBridge, WikiLink,
};

/// The shared fixture palace root, relative to the crate manifest (the
/// Swift suite reaches the same directory via `#filePath`).
const FIXTURE_PALACE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../Tests/VaultKitTests/Fixtures/mempalace"
);

/// Fixed operation instant (ms) so the bridge import is deterministic.
const NOW: i64 = 1_765_000_000_000;

fn fixture_notes() -> Vec<NoteIR> {
    MemPalaceChromaAdapter::new()
        .to_ir(Path::new(FIXTURE_PALACE))
        .expect("fixture palace must read")
}

fn note<'a>(key: &str, notes: &'a [NoteIR]) -> &'a NoteIR {
    notes
        .iter()
        .find(|n| n.stable_source_key == key)
        .unwrap_or_else(|| panic!("note {key} must exist"))
}

fn fm(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

// MARK: - Deterministic shape

#[test]
fn fixture_palace_maps_all_three_stores_sorted_by_stable_key_bytes() {
    let notes = fixture_notes();
    // 5 chroma rows + 2 tunnels + 2 KG entities + 2 KG triples.
    assert_eq!(notes.len(), 11);
    let keys: Vec<&str> = notes.iter().map(|n| n.stable_source_key.as_str()).collect();
    assert_eq!(
        keys,
        vec![
            "aaaa000011112222",
            "bbbb000011112222",
            "closet_clarity_0004",
            "closet_entities_0005",
            "diary_fulcrum_0002",
            "drawer_alpha_0001",
            "drawer_min_0003",
            "fleet",
            "skippy",
            "t_fleet_works_with_skippy_0001",
            "t_minimal_0002",
        ]
    );
    let kinds: Vec<&str> = notes.iter().map(|n| n.kind.as_str()).collect();
    assert_eq!(
        kinds,
        vec![
            "tunnel",
            "tunnel",
            "closet_summary",
            "closet_summary",
            "diary_entry",
            "drawer",
            "drawer",
            "kg_entity",
            "kg_entity",
            "kg_triple",
            "kg_triple",
        ]
    );
}

// MARK: - Store 1: chroma rows

#[test]
fn full_drawer_row_verbatim_frontmatter_placement_entities_facts_source() {
    let notes = fixture_notes();
    let n = note("drawer_alpha_0001", &notes);
    assert_eq!(n.kind, "drawer");
    assert_eq!(n.body, vec![Block::markdown("Alpha decision content with detail.")]);
    // Frontmatter keys VERBATIM — no prefixes; numerics in SQLite's own
    // text form (the cross-port float determinism anchor).
    assert_eq!(
        n.frontmatter,
        fm(&[
            ("wing", "mootx01"),
            ("hall", "hall_general"),
            ("room", "decisions"),
            ("filed_at", "2026-05-04T19:58:47.837740"),
            ("source_file", "notes/alpha.md"),
            ("source_mtime", "1746678432.25"),
            ("chunk_index", "0"),
            ("added_by", "skippy"),
            ("normalize_version", "3"),
            ("entities", "Fleet;Skippy"),
        ])
    );
    assert_eq!(n.path_components, vec!["mootx01", "hall_general", "decisions"]);
    assert_eq!(n.original_path, "mootx01/hall_general/decisions");
    // filed_at normalized: microseconds truncated to milliseconds, UTC.
    assert_eq!(
        n.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-05-04T19:58:47.837Z")
    );
    assert_eq!(n.source, Some(SourceRef::new("notes/alpha.md", "", None, None)));
    // entities → one mention fact per name, anchored to this note.
    assert_eq!(
        n.facts,
        vec![
            FactIR::new("Fleet", "mentioned_in", "drawer_alpha_0001"),
            FactIR::new("Skippy", "mentioned_in", "drawer_alpha_0001"),
        ]
    );
    assert!(n.links.is_empty());
    assert!(n.tags.is_empty());
    assert!(n.scope.is_empty());
    assert!(n.moot_id.is_none());
}

#[test]
fn diary_row_kind_diary_entry_diary_keys_verbatim() {
    let notes = fixture_notes();
    let n = note("diary_fulcrum_0002", &notes);
    assert_eq!(n.kind, "diary_entry");
    assert_eq!(n.frontmatter.get("type").map(String::as_str), Some("diary_entry"));
    assert_eq!(n.frontmatter.get("date").map(String::as_str), Some("2026-05-08"));
    assert_eq!(n.frontmatter.get("agent").map(String::as_str), Some("skippy"));
    assert_eq!(n.frontmatter.get("topic").map(String::as_str), Some("handoff"));
    assert_eq!(
        n.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-05-08T04:27:12.542Z")
    );
    assert_eq!(n.path_components, vec!["fulcrum", "hall_diary", "diary"]);
    assert!(n.source.is_none());
}

#[test]
fn minimal_drawer_row_no_hall_current_timestamp_filed_at_shape() {
    let notes = fixture_notes();
    let n = note("drawer_min_0003", &notes);
    assert_eq!(n.kind, "drawer");
    assert_eq!(n.path_components, vec!["mootx01", "storage"]);
    assert_eq!(n.original_path, "mootx01/storage");
    // " " separator normalized to "T", fraction synthesized.
    assert_eq!(
        n.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-04-28T02:48:07.000Z")
    );
    assert!(n.facts.is_empty());
}

#[test]
fn closet_rows_kind_closet_summary_drawer_count_rides_verbatim() {
    let notes = fixture_notes();
    let clarity = note("closet_clarity_0004", &notes);
    assert_eq!(clarity.kind, "closet_summary");
    assert_eq!(clarity.frontmatter.get("drawer_count").map(String::as_str), Some("12"));
    assert_eq!(
        clarity.body.first().map(|b| b.text.as_str()),
        Some("clarity|Fleet|summary of twelve drawers")
    );

    let entities = note("closet_entities_0005", &notes);
    assert_eq!(entities.kind, "closet_summary");
    assert_eq!(
        entities.facts,
        vec![
            FactIR::new("Not", "mentioned_in", "closet_entities_0005"),
            FactIR::new("Skippy", "mentioned_in", "closet_entities_0005"),
        ]
    );
    // Microsecond fraction truncates, not rounds: .000001 → .000.
    assert_eq!(
        entities.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-05-01T00:00:00.000Z")
    );
}

// MARK: - Store 2: tunnels

#[test]
fn labeled_tunnel_wikilink_to_target_endpoints_in_frontmatter() {
    let notes = fixture_notes();
    let n = note("aaaa000011112222", &notes);
    assert_eq!(n.kind, "tunnel");
    assert_eq!(n.body, vec![Block::markdown("Decision informs diary handoff")]);
    assert_eq!(
        n.links,
        vec![WikiLink::new("fulcrum/diary", None, "Decision informs diary handoff")]
    );
    assert_eq!(
        n.frontmatter,
        fm(&[
            ("source_wing", "mootx01"),
            ("source_room", "decisions"),
            ("target_wing", "fulcrum"),
            ("target_room", "diary"),
            ("created_at", "2026-05-29T08:38:47.205501+00:00"),
        ])
    );
    assert_eq!(n.path_components, vec!["mootx01", "decisions"]);
    assert_eq!(n.original_path, "mootx01/decisions");
    // "+00:00" offset stripped, microseconds truncated.
    assert_eq!(
        n.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-05-29T08:38:47.205Z")
    );
}

#[test]
fn unlabeled_tunnel_endpoint_fallback_keeps_body_and_link_non_empty() {
    let notes = fixture_notes();
    let n = note("bbbb000011112222", &notes);
    assert_eq!(n.body, vec![Block::markdown("fulcrum/diary -> mootx01/storage")]);
    assert_eq!(
        n.links,
        vec![WikiLink::new("mootx01/storage", None, "fulcrum/diary -> mootx01/storage")]
    );
    assert!(n.frontmatter.get("created_at").is_none());
    assert!(n.origin_date.is_none());
}

// MARK: - Store 3: knowledge graph

#[test]
fn kg_entity_rows_name_type_properties_verbatim() {
    let notes = fixture_notes();
    let skippy = note("skippy", &notes);
    assert_eq!(skippy.kind, "kg_entity");
    assert_eq!(skippy.body, vec![Block::markdown("Skippy")]);
    assert_eq!(
        skippy.frontmatter,
        fm(&[
            ("name", "Skippy"),
            ("type", "agent"),
            ("properties", "{\"role\": \"ai\"}"),
            ("created_at", "2026-04-28 02:50:08"),
        ])
    );
    assert_eq!(skippy.path_components, vec!["knowledge_graph", "entities"]);
    assert_eq!(
        skippy.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-04-28T02:50:08.000Z")
    );
    assert!(skippy.facts.is_empty());
}

#[test]
fn kg_triple_rows_fact_ir_with_validity_window_confidence_provenance() {
    let notes = fixture_notes();
    let full = note("t_fleet_works_with_skippy_0001", &notes);
    assert_eq!(full.kind, "kg_triple");
    assert_eq!(full.body, vec![Block::markdown("fleet works_with skippy")]);
    assert_eq!(
        full.facts,
        vec![FactIR {
            subject: "fleet".to_owned(),
            predicate: "works_with".to_owned(),
            object: "skippy".to_owned(),
            valid_from: Some("2026-04-27".to_owned()),
            valid_to: None,
            confidence: Some(1.0),
        }]
    );
    assert_eq!(
        full.frontmatter,
        fm(&[
            ("source_closet", "closet_clarity_0004"),
            ("source_file", "notes/alpha.md"),
            ("source_drawer_id", "drawer_alpha_0001"),
            ("adapter_name", "general"),
            ("extracted_at", "2026-04-28 02:48:07"),
        ])
    );
    assert_eq!(full.source, Some(SourceRef::new("notes/alpha.md", "", None, None)));
    assert_eq!(full.path_components, vec!["knowledge_graph", "triples"]);
    assert_eq!(
        full.origin_date.as_ref().map(|d| d.iso8601.as_str()),
        Some("2026-04-28T02:48:07.000Z")
    );

    let minimal = note("t_minimal_0002", &notes);
    assert_eq!(minimal.body, vec![Block::markdown("skippy knows fleet")]);
    assert_eq!(
        minimal.facts,
        vec![FactIR {
            subject: "skippy".to_owned(),
            predicate: "knows".to_owned(),
            object: "fleet".to_owned(),
            valid_from: None,
            valid_to: None,
            confidence: Some(0.75),
        }]
    );
    assert!(minimal.frontmatter.is_empty());
    assert!(minimal.source.is_none());
    assert!(minimal.origin_date.is_none());
}

// MARK: - Timestamp normalization

#[test]
fn canonical_iso8601_the_four_mem_palace_shapes_plus_rejections() {
    let f = canonical_iso8601_from_mem_palace;
    // Naive microseconds (filed_at) — truncate to milliseconds, UTC.
    assert_eq!(f("2026-05-08T04:27:12.542283").as_deref(), Some("2026-05-08T04:27:12.542Z"));
    // Explicit UTC offset (tunnel created_at).
    assert_eq!(
        f("2026-05-29T08:38:47.205501+00:00").as_deref(),
        Some("2026-05-29T08:38:47.205Z")
    );
    // SQLite CURRENT_TIMESTAMP (KG rows).
    assert_eq!(f("2026-04-28 02:48:07").as_deref(), Some("2026-04-28T02:48:07.000Z"));
    // Date-only (diary `date`).
    assert_eq!(f("2026-05-08").as_deref(), Some("2026-05-08T00:00:00.000Z"));
    // Short fraction pads; trailing Z accepted.
    assert_eq!(f("2026-05-08T04:27:12.5").as_deref(), Some("2026-05-08T04:27:12.500Z"));
    assert_eq!(f("2026-05-08T04:27:12.542Z").as_deref(), Some("2026-05-08T04:27:12.542Z"));
    // Non-UTC offsets are rejected (no tz arithmetic), as is garbage.
    assert_eq!(f("2026-05-08T04:27:12+02:00"), None);
    assert_eq!(f("2026-05-08T04:27:12-05:00"), None);
    assert_eq!(f("not a date"), None);
    assert_eq!(f("2026-05-08T04:27"), None);
    assert_eq!(f(""), None);
}

// MARK: - Read-only direction

#[test]
fn from_ir_is_rejected_mem_palace_is_a_source_never_a_destination() {
    let err = MemPalaceChromaAdapter::new()
        .from_ir(&[], Path::new(FIXTURE_PALACE))
        .expect_err("write direction must be rejected");
    assert!(matches!(err, vault_kit::VaultKitError::AdapterError(_)));
}

#[test]
fn missing_chroma_store_errors_not_silence() {
    let bogus = std::env::temp_dir().join(format!("no-palace-{}", uuid::Uuid::new_v4()));
    let err = MemPalaceChromaAdapter::new()
        .to_ir(&bogus)
        .expect_err("missing chroma store must error");
    assert!(matches!(err, vault_kit::VaultKitError::AdapterError(_)));
}

// MARK: - Bridge entry point

fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("mempalace-tests"), 0, 100)
        .expect("open");
    (coord, handle)
}

#[test]
fn import_mem_palace_fixture_palace_lands_in_estate_idempotent_on_reimport() {
    let (coord, handle) = open_one();
    // The bridge's constructor adapter handles `import_vault`; the
    // MemPalace lane passes its adapter explicitly.
    let bridge =
        VaultBridge::new(&coord, Box::new(ObsidianAdapter::new()), DrawerMapping::default());
    let adapter = MemPalaceChromaAdapter::new();

    let first = bridge
        .import_mem_palace(Path::new(FIXTURE_PALACE), &handle, NOW, &adapter)
        .expect("first import");
    // All 11 notes have non-empty content (I-5 fallbacks hold), so every
    // one captures; the 2 tunnel notes each carry one wikilink.
    assert_eq!(first.drawers_written, 11);
    assert_eq!(first.drawers_updated, 0);
    assert_eq!(first.items_skipped, 0);
    assert_eq!(first.tunnels_created, 2);
    assert_eq!(first.fdc_classified + first.fdc_unclassified, 11);

    // Idempotency: a re-import supersedes every lineage (updated, not
    // duplicated) and re-creates no tunnels.
    let second = bridge
        .import_mem_palace(Path::new(FIXTURE_PALACE), &handle, NOW, &adapter)
        .expect("second import");
    assert_eq!(second.drawers_written, 0);
    assert_eq!(second.drawers_updated, 11);
    assert_eq!(second.tunnels_created, 0);
}

// MARK: - Real-palace integration (guarded)

#[test]
fn real_mempalace_imports_with_the_expected_store_counts() {
    let Some(home) = std::env::var_os("HOME") else { return };
    let root = PathBuf::from(home).join(".mempalace");
    // Guarded: runs only on a machine that has a live palace.
    if !root.join("palace/chroma.sqlite3").exists() {
        return;
    }

    let notes = MemPalaceChromaAdapter::new()
        .to_ir(&root)
        .expect("live palace must read");
    let mut by_kind: HashMap<&str, usize> = HashMap::new();
    for n in &notes {
        *by_kind.entry(n.kind.as_str()).or_insert(0) += 1;
    }

    // Verified against the live palace 2026-06-10: 39,777 drawer rows
    // (2,281 of them diary), 7,525 closets, 959 KG entities, 810 KG
    // triples. The palace is live and append-mostly, so the floor is
    // asserted (>=) rather than equality.
    let drawer_rows =
        by_kind.get("drawer").copied().unwrap_or(0) + by_kind.get("diary_entry").copied().unwrap_or(0);
    assert!(drawer_rows >= 39_777, "drawer rows: {drawer_rows}");
    assert!(by_kind.get("diary_entry").copied().unwrap_or(0) >= 2_281);
    assert!(by_kind.get("closet_summary").copied().unwrap_or(0) >= 7_525);
    assert!(by_kind.get("kg_entity").copied().unwrap_or(0) >= 959);
    assert!(by_kind.get("kg_triple").copied().unwrap_or(0) >= 810);
    assert!(by_kind.get("tunnel").copied().unwrap_or(0) >= 1);

    // Spot-check fidelity invariants over the whole palace: stable keys
    // are unique and every chroma row carries its placement.
    let unique: std::collections::HashSet<&str> =
        notes.iter().map(|n| n.stable_source_key.as_str()).collect();
    assert_eq!(unique.len(), notes.len());
    for n in notes
        .iter()
        .filter(|n| matches!(n.kind.as_str(), "drawer" | "diary_entry" | "closet_summary"))
    {
        assert!(n.frontmatter.contains_key("wing"), "{} missing wing", n.stable_source_key);
        assert!(n.frontmatter.contains_key("room"), "{} missing room", n.stable_source_key);
        assert!(n.frontmatter.contains_key("filed_at"), "{} missing filed_at", n.stable_source_key);
    }
}
