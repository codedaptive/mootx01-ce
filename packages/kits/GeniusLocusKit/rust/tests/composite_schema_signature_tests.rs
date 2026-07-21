//! Composite-schema layout-signature parity gate
//! (GLK shared-content 1.1, P0).
//!
//! The composite estate schema must be DERIVED from the live component
//! declarations — never asserted by a copied version comment. These tests
//! pin that derivation structurally:
//!
//!   1. the composite version equals the sum of the live component
//!      versions plus the two GLK-owned addends;
//!   2. the composite's canonical layout signature matches the frozen
//!      cross-port fixture (`Tests/Fixtures/composite_schema_signature.txt`),
//!      which the Swift twin (`CompositeSchemaSignatureTests`) asserts
//!      byte-identically — so the two ports cannot silently diverge in any
//!      table, column, key, or index of the pre-cutover layout.
//!
//! When a deliberate schema change lands (e.g. the shared-content attached
//! cutover), regenerate the fixture in BOTH ports' test runs and commit the
//! new file with the schema change — the diff of the fixture IS the layout
//! review artifact.

use genius_locus_kit::hydration::composite_schema;
use persistence_kit::layout_signature::layout_signature_text;
use std::path::PathBuf;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Fixtures/composite_schema_signature.txt")
}

#[test]
fn composite_version_is_sum_of_live_component_versions() {
    let composite = composite_schema();
    let expected = locus_kit::schema::schema().version
        + vectorkit::VectorStore::schema_declaration().version
        + vectorkit::VectorRepresentationClaims::schema_declaration().version
        + corpus_kit::attached_declaration().version
        + 1  // grants
        + genius_locus_kit::matrix::MatrixSnapshotStore::schema_declaration().version;
    assert_eq!(composite.version, expected);
}

#[test]
fn composite_table_names_are_unique() {
    let composite = composite_schema();
    let mut names: Vec<&str> = composite.tables.iter().map(|t| t.name.as_str()).collect();
    let total = names.len();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), total, "duplicate table in composite schema");
}

#[test]
fn composite_signature_matches_frozen_cross_port_fixture() {
    let actual = layout_signature_text(&composite_schema());
    // Maintainer regen: MOOT_REGEN_COMPOSITE_FIXTURE=1 rewrites the fixture
    // from THIS port; run the Swift twin the same way and verify the two
    // runs produce a byte-identical file before committing.
    if std::env::var("MOOT_REGEN_COMPOSITE_FIXTURE").as_deref() == Ok("1") {
        std::fs::write(fixture_path(), &actual).expect("write fixture");
    }
    let expected = std::fs::read_to_string(fixture_path())
        .expect("read Tests/Fixtures/composite_schema_signature.txt");
    assert_eq!(
        actual, expected,
        "composite layout signature diverged from the frozen fixture — if this \
         change is deliberate, regenerate the fixture in both ports"
    );
}
