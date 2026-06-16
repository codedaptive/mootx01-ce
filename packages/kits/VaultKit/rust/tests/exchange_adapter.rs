//! ExchangeAdapter decode (VK-ADAPT-01) + encode/write side
//! (VK-EXPORT-01) + corpus_projection conformance tests.
//!
//! Loads the SAME fixtures the Swift suite
//! (`Tests/VaultKitTests/ExchangeAdapterTests.swift`) exercises and
//! asserts the same decoded values — and, for the write side, the SAME
//! canonical bytes (`exchange_export_canonical.json`), the
//! cross-language byte-identity contract for `encode`. Any change to a
//! fixture must keep both suites green in the same commit.

use std::path::Path;

use vault_kit::{Block, FactIR, ExchangeAdapter, ExchangeExport, NoteIR, VaultAdapter, VaultKitError};

/// Path of the shared golden fixture, relative to the crate manifest.
const FIXTURE_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../Tests/VaultKitTests/Fixtures/exchange_export_golden.json"
);

/// Path of the shared canonical write-side fixture: the byte-exact
/// canonical encode of the golden fixture, asserted by both suites.
const CANONICAL_FIXTURE_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../Tests/VaultKitTests/Fixtures/exchange_export_canonical.json"
);

fn fixture_bytes() -> Vec<u8> {
    std::fs::read(FIXTURE_PATH).expect("golden fixture must exist")
}

#[test]
fn golden_fixture_decodes_name_sorted_keys_and_field_mapping() {
    let export = ExchangeAdapter::new().decode(&fixture_bytes()).expect("decode");

    assert_eq!(export.name, "golden-palace");
    // Deterministic order: sorted by stable_source_key even though the
    // fixture lists drawer-002 first.
    let keys: Vec<&str> =
        export.notes.iter().map(|n| n.stable_source_key.as_str()).collect();
    assert_eq!(keys, ["drawer-001", "drawer-002", "drawer-003"]);

    let full = &export.notes[0];
    assert_eq!(full.flattened_body(), "Alice works at Acme.");
    assert_eq!(full.body, vec![Block::markdown("Alice works at Acme.")]);
    assert_eq!(full.tags, vec!["org".to_string(), "people".to_string()]);
    let mut fact = FactIR::new("alice", "works_at", "acme");
    fact.valid_from = Some("2024-03-04T05:06:07.000Z".to_string());
    fact.confidence = Some(0.9);
    assert_eq!(full.facts, vec![fact]);
    assert_eq!(full.path_components, vec!["work".to_string(), "people".to_string()]);
    assert_eq!(full.original_path, "work/people");
    assert_eq!(full.scope.get("agentId").map(String::as_str), Some("ag-7"));
    assert_eq!(full.kind, "fact");
}

#[test]
fn absent_extended_fields_land_documented_defaults() {
    let export = ExchangeAdapter::new().decode(&fixture_bytes()).expect("decode");

    // drawer-002 carries only id/content/tags — the legacy flat shape.
    let flat = &export.notes[1];
    assert!(flat.tags.is_empty());
    assert!(flat.facts.is_empty());
    assert!(flat.path_components.is_empty());
    assert_eq!(flat.original_path, "");
    assert!(flat.scope.is_empty());
    assert_eq!(flat.kind, "note");
    assert!(flat.frontmatter.is_empty());
    assert!(flat.links.is_empty());
    assert!(flat.moot_id.is_none());
}

#[test]
fn tags_key_may_be_omitted_entirely() {
    let json = br#"{ "name": "n", "entries": [ { "id": "a", "content": "c" } ] }"#;
    let export = ExchangeAdapter::new().decode(json).expect("decode");
    assert_eq!(export.notes.len(), 1);
    assert!(export.notes[0].tags.is_empty());
}

#[test]
fn malformed_export_errors() {
    let adapter = ExchangeAdapter::new();
    // Not JSON at all.
    assert!(matches!(
        adapter.decode(b"not json"),
        Err(VaultKitError::Serialization(_))
    ));
    // Missing required `content`.
    assert!(matches!(
        adapter.decode(br#"{ "name": "n", "entries": [ { "id": "a" } ] }"#),
        Err(VaultKitError::Serialization(_))
    ));
    // Missing required top-level `name`.
    assert!(matches!(
        adapter.decode(br#"{ "entries": [] }"#),
        Err(VaultKitError::Serialization(_))
    ));
}

#[test]
fn to_ir_reads_the_export_file() {
    let notes = ExchangeAdapter::new().to_ir(Path::new(FIXTURE_PATH)).expect("to_ir");
    let keys: Vec<&str> = notes.iter().map(|n| n.stable_source_key.as_str()).collect();
    assert_eq!(keys, ["drawer-001", "drawer-002", "drawer-003"]);
}

// MARK: Write side (VK-EXPORT-01 — the programmatic exit promise)

fn temp_export_path(file: &str) -> std::path::PathBuf {
    std::env::temp_dir()
        .join(format!("vk-export-01-{}", uuid::Uuid::new_v4()))
        .join(file)
}

#[test]
fn round_trip_to_ir_from_ir_golden_fixture() {
    let adapter = ExchangeAdapter::new();
    let notes = adapter.to_ir(Path::new(FIXTURE_PATH)).expect("to_ir");
    let out = temp_export_path("golden-palace.json");
    adapter.from_ir(&notes, &out).expect("from_ir");
    let reread = adapter.to_ir(&out).expect("re-read");
    assert_eq!(reread, notes);
}

#[test]
fn round_trip_generated_format_representable_notes() {
    let adapter = ExchangeAdapter::new();
    // Format-representable fields only; includes unicode, slashes, and
    // quotes in content (mirrors the Swift generated-cases test).
    let mut rich = NoteIR::new(
        "gen-001",
        vec![Block::markdown("Slash /path/ and \"quotes\" and ünïcödé ✓")],
        std::collections::HashMap::new(),
        Vec::new(),
        vec!["a".to_string(), "b".to_string()],
        "x/y",
        None,
        None,
    );
    let mut fact2 = FactIR::new("s2", "p2", "o2");
    fact2.valid_from = Some("2024-01-02T03:04:05.000Z".to_string());
    fact2.valid_to = Some("2025-01-02T03:04:05.000Z".to_string());
    fact2.confidence = Some(0.5);
    rich.facts = vec![FactIR::new("s", "p", "o"), fact2];
    rich.path_components = vec!["x".to_string(), "y".to_string()];
    rich.scope.insert("userId".to_string(), "u-1".to_string());
    rich.scope.insert("agentId".to_string(), "ag-2".to_string());
    rich.kind = "journal".to_string();
    let flat = NoteIR::new(
        "gen-000-flat",
        vec![Block::markdown("flat legacy shape")],
        std::collections::HashMap::new(),
        Vec::new(),
        Vec::new(),
        "",
        None,
        None,
    );
    let generated = vec![rich, flat];

    let out = temp_export_path("generated.json");
    adapter.from_ir(&generated, &out).expect("from_ir");
    let reread = adapter.to_ir(&out).expect("re-read");
    // to_ir returns sorted by stable_source_key; compare same order.
    let mut expected = generated;
    expected.sort_by(|a, b| a.stable_source_key.cmp(&b.stable_source_key));
    assert_eq!(reread, expected);
}

#[test]
fn canonical_encode_matches_shared_byte_identity_fixture() {
    let adapter = ExchangeAdapter::new();
    let export = adapter.decode(&fixture_bytes()).expect("decode");
    let encoded = adapter.encode(&export).expect("encode");
    let expected =
        std::fs::read(CANONICAL_FIXTURE_PATH).expect("canonical fixture must exist");
    assert_eq!(encoded.as_bytes(), expected.as_slice());
}

#[test]
fn re_encode_is_byte_stable() {
    let adapter = ExchangeAdapter::new();
    let first = adapter
        .encode(&adapter.decode(&fixture_bytes()).expect("decode"))
        .expect("encode");
    let second = adapter
        .encode(&adapter.decode(first.as_bytes()).expect("re-decode"))
        .expect("re-encode");
    assert_eq!(first, second);
}

#[test]
fn encode_preserves_name_and_decode_reads_it_back() {
    let adapter = ExchangeAdapter::new();
    let export = ExchangeExport {
        name: "my-palace".to_string(),
        notes: vec![NoteIR::new(
            "n1",
            vec![Block::markdown("hello")],
            std::collections::HashMap::new(),
            Vec::new(),
            Vec::new(),
            "",
            None,
            None,
        )],
    };
    let decoded = adapter
        .decode(adapter.encode(&export).expect("encode").as_bytes())
        .expect("decode");
    assert_eq!(decoded.name, "my-palace");
    assert_eq!(decoded.notes, export.notes);
}

#[test]
fn from_ir_derives_name_from_destination_filename() {
    let adapter = ExchangeAdapter::new();
    let out = temp_export_path("my-estate.json");
    let note = NoteIR::new(
        "n1",
        vec![Block::markdown("x")],
        std::collections::HashMap::new(),
        Vec::new(),
        Vec::new(),
        "",
        None,
        None,
    );
    adapter.from_ir(&[note], &out).expect("from_ir");
    let decoded = adapter
        .decode(&std::fs::read(&out).expect("read"))
        .expect("decode");
    assert_eq!(decoded.name, "my-estate");
}

#[test]
fn from_ir_creates_directories_and_is_deterministic() {
    let adapter = ExchangeAdapter::new();
    let notes = adapter.to_ir(Path::new(FIXTURE_PATH)).expect("to_ir");
    let out = std::env::temp_dir()
        .join(format!("vk-export-01-{}", uuid::Uuid::new_v4()))
        .join("deep/nested/palace.json");
    adapter.from_ir(&notes, &out).expect("from_ir");
    let first = std::fs::read(&out).expect("read");
    // Same notes in reversed order: identical bytes (canonical sort).
    let reversed: Vec<NoteIR> = notes.into_iter().rev().collect();
    adapter.from_ir(&reversed, &out).expect("from_ir again");
    let second = std::fs::read(&out).expect("re-read");
    assert_eq!(first, second);
}

#[test]
fn projection_maps_notes_back_to_external_corpus_entries() {
    let export = ExchangeAdapter::new().decode(&fixture_bytes()).expect("decode");
    let corpus = vault_kit::corpus_projection::external_corpus(&export.name, &export.notes);

    assert_eq!(corpus.name, "golden-palace");
    assert_eq!(corpus.entries.len(), 3);
    assert_eq!(corpus.entries[0].id, "drawer-001");
    assert_eq!(corpus.entries[0].content, "Alice works at Acme.");
    assert_eq!(corpus.entries[0].tags, vec!["org".to_string(), "people".to_string()]);
    let projected_ids: Vec<&str> = corpus.entries.iter().map(|e| e.id.as_str()).collect();
    let note_keys: Vec<&str> =
        export.notes.iter().map(|n| n.stable_source_key.as_str()).collect();
    assert_eq!(projected_ids, note_keys);
}
