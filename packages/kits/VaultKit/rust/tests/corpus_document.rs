//! VK_IR_01 — CorpusDocument cross-language conformance tests.
//!
//! Loads the SAME golden fixture the Swift suite exercises
//! (`Tests/VaultKitTests/Fixtures/corpus_document_v1.json`, reached
//! relative to CARGO_MANIFEST_DIR) and asserts byte-for-byte encode
//! equality plus value-for-value decode equality. The golden document
//! constructed here mirrors Swift
//! `CorpusDocumentTests.goldenDocument()` field for field — change one,
//! change both, same commit.

use std::collections::{BTreeMap, HashMap};

use vault_kit::{
    Block, CorpusDocument, FactIR, NoteIR, OccurredAt, SourceRef, VaultKitError, WikiLink,
};

/// Path of the shared golden fixture, relative to the crate manifest.
const FIXTURE_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../Tests/VaultKitTests/Fixtures/corpus_document_v1.json"
);

/// The canonical sample document — the Rust twin of Swift
/// `CorpusDocumentTests.goldenDocument()`.
fn golden_document() -> CorpusDocument {
    let mut frontmatter = HashMap::new();
    frontmatter.insert("created".to_owned(), "2024-03-04T05:06:07.000Z".to_owned());
    frontmatter.insert("wing".to_owned(), "work".to_owned());

    let mut scope = BTreeMap::new();
    scope.insert("agentId".to_owned(), "ag-7".to_owned());
    scope.insert("userId".to_owned(), "u-1".to_owned());

    let mut full_fidelity_note = NoteIR::with_moot_id(
        "projects/alpha/fact-sheet",
        vec![Block::new("markdown", "Alice works at Acme.\nSee [[Acme HQ|HQ]].")],
        frontmatter,
        vec![WikiLink::new("Acme HQ", Some("HQ".to_owned()), "Acme HQ|HQ")],
        vec!["org".to_owned(), "people".to_owned()],
        "projects/alpha",
        Some(OccurredAt::new("2024-03-04T05:06:07.000Z")),
        Some(SourceRef::new(
            "attachments/acme.pdf",
            "ab12cd34",
            Some("application/pdf".to_owned()),
            Some(2048),
        )),
        Some(uuid::Uuid::parse_str("E621E1F8-C36C-495A-93FC-0C247A3E6E5F").unwrap()),
    );
    full_fidelity_note.facts = vec![
        FactIR {
            subject: "alice".to_owned(),
            predicate: "works_at".to_owned(),
            object: "acme".to_owned(),
            valid_from: Some("2024-03-04T05:06:07.000Z".to_owned()),
            valid_to: None,
            confidence: Some(0.9),
        },
        FactIR::new("acme", "located_in", "berlin"),
    ];
    full_fidelity_note.path_components = vec!["projects".to_owned(), "alpha".to_owned()];
    full_fidelity_note.scope = scope;
    full_fidelity_note.kind = "fact".to_owned();

    let minimal_note = NoteIR::new(
        "inbox/hello",
        vec![Block::markdown("hello world")],
        HashMap::new(),
        vec![],
        vec![],
        "",
        None,
        None,
    );

    CorpusDocument::new("golden-estate", vec![full_fidelity_note, minimal_note])
}

fn fixture() -> String {
    std::fs::read_to_string(FIXTURE_PATH).expect("golden fixture must exist")
}

#[test]
fn encode_matches_fixture_byte_for_byte() {
    let encoded = golden_document().canonical_json().expect("encode");
    assert_eq!(encoded, fixture(), "canonical encode diverged from the shared fixture");
}

#[test]
fn decode_fixture_yields_expected_values() {
    let decoded = CorpusDocument::decode(&fixture()).expect("decode");
    assert_eq!(decoded, golden_document());
    assert_eq!(decoded.format_version, 1);
    assert_eq!(decoded.notes.len(), 2);
    assert_eq!(decoded.notes[0].facts.len(), 2);
    assert_eq!(decoded.notes[1].kind, "note");
}

#[test]
fn canonical_encode_is_deterministic() {
    let a = golden_document().canonical_json().expect("encode a");
    let b = golden_document().canonical_json().expect("encode b");
    assert_eq!(a, b);
}

#[test]
fn unknown_format_version_is_typed_error() {
    let err = CorpusDocument::decode(r#"{"formatVersion":2,"name":"future","notes":[]}"#)
        .expect_err("must reject unknown version");
    match err {
        VaultKitError::UnsupportedFormatVersion(v) => assert_eq!(v, 2),
        other => panic!("expected UnsupportedFormatVersion, got {other:?}"),
    }
}

#[test]
fn version_checked_before_notes_parsing() {
    // `notes` is structurally invalid; the strict decoder must reject on
    // formatVersion BEFORE ever shaping it.
    let err = CorpusDocument::decode(r#"{"formatVersion":99,"name":"x","notes":[{"bogus":true}]}"#)
        .expect_err("must reject unknown version");
    match err {
        VaultKitError::UnsupportedFormatVersion(v) => assert_eq!(v, 99),
        other => panic!("expected UnsupportedFormatVersion, got {other:?}"),
    }
}

#[test]
fn legacy_pre_extension_note_json_decodes_with_defaults() {
    // Shape exactly as the pre-extension Swift encoder produced it: the
    // nine original NoteIR fields only, optionals omitted, no facts/
    // pathComponents/scope/kind keys.
    let legacy = r#"{"formatVersion":1,"name":"old","notes":[{"body":[{"kind":"markdown","text":"hello"}],"frontmatter":{"wing":"w"},"links":[],"originalPath":"projects/alpha","stableSourceKey":"alpha/hello","tags":["t1"]}]}"#;
    let decoded = CorpusDocument::decode(legacy).expect("legacy decode");
    let note = &decoded.notes[0];
    assert_eq!(note.stable_source_key, "alpha/hello");
    assert!(note.facts.is_empty());
    assert!(note.path_components.is_empty());
    assert!(note.scope.is_empty());
    assert_eq!(note.kind, "note");
}
