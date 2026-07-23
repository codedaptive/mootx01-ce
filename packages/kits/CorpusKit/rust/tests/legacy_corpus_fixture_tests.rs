//! Legacy-v7 corpus-lane fixture coverage (GLK shared-content 1.1, P0).
//! Rust twin of the Swift `LegacyCorpusFixtureTests` + `LegacyCorpusFixtures`.
//!
//! Pins the structural identity of the historical v7-era corpus lane —
//! the layout the P4 legacy detector must DISTINGUISH from the current
//! pre-cutover layout — and proves the fixture builder produces the
//! deterministic legacy-shaped rows destructive migration tests replay.
//!
//! The era declarations are LITERAL reconstructions of the 1.0.0-ship
//! layout (chunks v2: ext but no content_hash, no corpus_metadata;
//! vectors v3: no idx_vectors_filed_at_item). They must never be edited
//! to track live declarations. Their canonical layout signature is frozen
//! cross-port in `Tests/Fixtures/legacy_v7_corpus_lane_signature.txt`.

use corpus_kit::{BundleStore, Chunk};
use persistence_kit::database_inventory::capture_inventory;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::layout_signature::layout_signature_text;
use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, IndexDeclaration,
    SchemaDeclaration, Storage, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use substrate_types::hlc::HLC;
use uuid::Uuid;
use vectorkit::VectorStore;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Fixtures/legacy_v7_corpus_lane_signature.txt")
}

/// CorpusKit BundleStore schema as of v2 (pre content-hash, pre
/// corpus_metadata). Literal, frozen.
fn legacy_chunks_declaration() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "CorpusKit",
        2,
        vec![TableDeclaration::new(
            "chunks",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("source_id"),
                ColumnDeclaration::int("start_offset"),
                ColumnDeclaration::int("length"),
                ColumnDeclaration::text("text"),
                ColumnDeclaration::hlc("hlc"),
                ColumnDeclaration::json("metadata"),
                ColumnDeclaration::timestamp("created_at"),
                ColumnDeclaration::json("ext").nullable(),
            ],
            vec!["id".to_string()],
        )],
    )
    .with_indices(vec![
        IndexDeclaration::new("idx_chunks_source", "chunks", vec!["source_id".to_string()]),
        IndexDeclaration::new("idx_chunks_hlc", "chunks", vec!["hlc".to_string()]),
    ])
}

/// VectorKit schema as of v3 (pre idx_vectors_filed_at_item). Literal, frozen.
fn legacy_vectors_declaration() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "VectorKit",
        3,
        vec![TableDeclaration::new(
            "vectors",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("item_id"),
                ColumnDeclaration::int("vector_index"),
                ColumnDeclaration::text("model_id"),
                ColumnDeclaration::text("model_version"),
                ColumnDeclaration::int("kind"),
                ColumnDeclaration::int("dim"),
                ColumnDeclaration::blob("payload"),
                ColumnDeclaration::float("scale").nullable(),
                ColumnDeclaration::timestamp("filed_at"),
                ColumnDeclaration::json("ext").nullable(),
            ],
            vec!["id".to_string()],
        )
        .with_unique_constraints(vec![vec![
            "item_id".to_string(),
            "vector_index".to_string(),
            "model_id".to_string(),
        ]])],
    )
    .with_indices(vec![
        IndexDeclaration::new("idx_vectors_item", "vectors", vec!["item_id".to_string()]),
        IndexDeclaration::new(
            "idx_vectors_model_item",
            "vectors",
            vec!["model_id".to_string(), "item_id".to_string()],
        ),
    ])
}

/// The combined legacy corpus-lane declaration whose layout signature is
/// frozen cross-port.
fn legacy_corpus_lane_declaration() -> SchemaDeclaration {
    let chunks = legacy_chunks_declaration();
    let vectors = legacy_vectors_declaration();
    let mut tables = chunks.tables.clone();
    tables.extend(vectors.tables.clone());
    let mut indices = chunks.indices.clone();
    indices.extend(vectors.indices.clone());
    SchemaDeclaration {
        kit_id: "LegacyCorpusLane".to_string(),
        version: chunks.version + vectors.version,
        tables,
        indices,
        migrations: vec![],
    }
}

/// The current pre-cutover corpus-lane declaration, from the LIVE
/// declarations — the comparison target for detection tests.
fn current_corpus_lane_declaration() -> SchemaDeclaration {
    let chunks = BundleStore::schema_declaration();
    let vectors = VectorStore::schema_declaration();
    let mut tables = chunks.tables.clone();
    tables.extend(vectors.tables.clone());
    let mut indices = chunks.indices.clone();
    indices.extend(vectors.indices.clone());
    SchemaDeclaration {
        kit_id: "CurrentCorpusLane".to_string(),
        version: chunks.version + vectors.version,
        tables,
        indices,
        migrations: vec![],
    }
}

const FIXTURE_NOW_MILLIS: i64 = 1_600_000_000_000;

const LEGACY_SOURCES: [(&str, &str); 2] = [
    (
        "drawer-legacy-1",
        "First legacy drawer content preserved verbatim in the chunk lane.",
    ),
    (
        "drawer-legacy-2",
        "Second legacy drawer content, also copied into chunks.",
    ),
];

/// Populate `storage` with a deterministic v7-era corpus lane. Returns the
/// chunk IDs per source — the exact-key deletion inventory a migration
/// must capture.
fn build_legacy_v7_corpus_lane(
    storage: &Arc<dyn Storage>,
) -> BTreeMap<String, Vec<Uuid>> {
    storage
        .migrate(&legacy_chunks_declaration())
        .expect("migrate legacy chunks");
    storage
        .migrate(&legacy_vectors_declaration())
        .expect("migrate legacy vectors");

    let row_store = storage.row_store();
    let mut chunk_ids_by_source: BTreeMap<String, Vec<Uuid>> = BTreeMap::new();
    let mut hlc_counter: i64 = 1;
    for (source_id, text) in LEGACY_SOURCES {
        let chunk_id = Chunk::derive_id(source_id, 0, text);
        chunk_ids_by_source
            .entry(source_id.to_string())
            .or_default()
            .push(chunk_id);

        let mut chunk_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        chunk_values.insert("id".into(), TypedValue::Uuid(chunk_id));
        chunk_values.insert("source_id".into(), TypedValue::Text(source_id.to_string()));
        chunk_values.insert("start_offset".into(), TypedValue::Int(0));
        chunk_values.insert("length".into(), TypedValue::Int(text.len() as i64));
        chunk_values.insert("text".into(), TypedValue::Text(text.to_string()));
        chunk_values.insert(
            "hlc".into(),
            TypedValue::Hlc(HLC {
                physical_time: hlc_counter,
                logical_count: 0,
                node_id: 1,
            }),
        );
        chunk_values.insert("metadata".into(), TypedValue::Json(b"{}".to_vec()));
        chunk_values.insert(
            "created_at".into(),
            TypedValue::Timestamp(FIXTURE_NOW_MILLIS),
        );
        chunk_values.insert("ext".into(), TypedValue::Null);
        row_store
            .insert("chunks", chunk_values)
            .expect("insert legacy chunk");

        // Chunk-keyed binary vector row (vector_index 0) — the legacy
        // CorpusKit artifact class the migration deletes by exact key.
        let vector_row_id =
            Uuid::parse_str(&format!("00000000-0000-4000-8000-{hlc_counter:012}"))
                .expect("deterministic vector row id");
        let mut vector_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        vector_values.insert("id".into(), TypedValue::Uuid(vector_row_id));
        vector_values.insert(
            "item_id".into(),
            TypedValue::Text(chunk_id.to_string().to_uppercase()),
        );
        vector_values.insert("vector_index".into(), TypedValue::Int(0));
        vector_values.insert(
            "model_id".into(),
            TypedValue::Text("corpus-deterministic-v1".into()),
        );
        vector_values.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        vector_values.insert("kind".into(), TypedValue::Int(0));
        vector_values.insert("dim".into(), TypedValue::Int(256));
        vector_values.insert(
            "payload".into(),
            TypedValue::Blob(vec![hlc_counter as u8; 32]),
        );
        vector_values.insert("scale".into(), TypedValue::Null);
        vector_values.insert(
            "filed_at".into(),
            TypedValue::Timestamp(FIXTURE_NOW_MILLIS),
        );
        row_store
            .insert("vectors", vector_values)
            .expect("insert legacy vector");
        hlc_counter += 1;
    }
    chunk_ids_by_source
}

fn fresh_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

#[test]
fn legacy_signature_matches_frozen_cross_port_fixture() {
    let expected = std::fs::read_to_string(fixture_path())
        .expect("read Tests/Fixtures/legacy_v7_corpus_lane_signature.txt");
    let actual = layout_signature_text(&legacy_corpus_lane_declaration());
    assert_eq!(
        actual, expected,
        "legacy corpus-lane signature diverged — the legacy declarations are \
         FROZEN history and must not track live declarations"
    );
}

#[test]
fn legacy_layout_is_distinguishable_from_current_layout() {
    let legacy = layout_signature_text(&legacy_corpus_lane_declaration());
    let current = layout_signature_text(&current_corpus_lane_declaration());
    assert_ne!(legacy, current);

    // The distinguishing marks the detector keys on: v3 BundleStore added
    // content_hash + corpus_metadata; VectorKit v4 added the filed_at index.
    assert!(!legacy.contains("col=content_hash"));
    assert!(current.contains("col=content_hash"));
    assert!(!legacy.contains("table=corpus_metadata"));
    assert!(current.contains("table=corpus_metadata"));
    assert!(!legacy.contains("index=idx_vectors_filed_at_item"));
    assert!(current.contains("index=idx_vectors_filed_at_item"));
}

#[test]
fn builder_produces_deterministic_legacy_rows() {
    let storage = fresh_storage();
    let chunk_ids = build_legacy_v7_corpus_lane(&storage);

    // One chunk + one chunk-keyed vector per legacy source; no
    // corpus_metadata table exists at v7.
    assert_eq!(chunk_ids.len(), LEGACY_SOURCES.len());
    let row_store = storage.row_store();
    assert_eq!(row_store.count("chunks", None).expect("count chunks"), 2);
    assert_eq!(row_store.count("vectors", None).expect("count vectors"), 2);
    assert!(row_store.count("corpus_metadata", None).is_err());

    // Vector rows are keyed by the legacy chunk UUIDs.
    let vector_rows = row_store
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let all_chunk_ids: Vec<String> = chunk_ids
        .values()
        .flatten()
        .map(|u| u.to_string().to_uppercase())
        .collect();
    for row in &vector_rows {
        if let Some(TypedValue::Text(item_id)) = row.get("item_id") {
            assert!(all_chunk_ids.contains(item_id));
        }
    }

    // Deterministic across builds: an identical fixture in a fresh storage
    // folds identically (fixture stamps are fixed — no exclusions needed).
    let storage2 = fresh_storage();
    build_legacy_v7_corpus_lane(&storage2);
    let inv1 = capture_inventory(&storage, &["chunks", "vectors"], &BTreeMap::new())
        .expect("inv1");
    let inv2 = capture_inventory(&storage2, &["chunks", "vectors"], &BTreeMap::new())
        .expect("inv2");
    assert_eq!(inv1, inv2);
}
