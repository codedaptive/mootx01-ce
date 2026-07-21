//! Shared-content 1.1 P6 — large-estate migration qualification driver.
//!
//! NOT part of any CI lane: the single test is `#[ignore]` and requires the
//! `MOOT_SCF_QUAL_DB` environment variable to name a RECOVERABLE CLONE of a
//! real legacy estate (never point it at a live estate — the migration
//! rewrites the corpus lane in place). Run it explicitly:
//!
//! ```text
//! MOOT_SCF_QUAL_DB=/path/to/clone.sqlite \
//!   cargo test --test scale_qualification -- --ignored --nocapture
//! ```
//!
//! The driver runs (or RESUMES — kill it mid-rebuild to exercise the
//! cursor-checkpoint resume at scale) the migration, completes the physical
//! reclaim, and prints `QUAL key=value` metric lines for the release
//! evidence: before/after page/freelist counts, database + WAL file bytes,
//! per-table bytes for the retired and rebuilt lanes, migration duration,
//! indexing progress, reclaim outcome, and post-migration recall latency
//! with direct Drawer-ID hydration proof.

use std::sync::Arc;
use std::time::Instant;

use corpus_kit::{
    CorpusContentConfiguration, CorpusContentEngine, CorpusContentSource, CorpusIndexUnitPolicy,
    CorpusOperatingMode,
};
use corpus_kit_providers::default_ensemble;
use genius_locus_kit::intake::LocusDrawerContentSource;
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{SharedContentMigrationExt, SharedContentMigrationState};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::Storage;

const NOW: i64 = 1_753_000_000_000;

fn q(label: &str, value: impl std::fmt::Display) {
    println!("QUAL {label}={value}");
}

/// FNV-1a fold over the exact ordered token stream consumed by the trainers.
/// Length prefixes make concatenation unambiguous and keep this diagnostic
/// independent of provider basis math.
fn token_stream_fingerprint(source: &LocusDrawerContentSource) -> Result<(String, usize), String> {
    fn fold(hash: &mut u64, bytes: &[u8]) {
        for byte in bytes {
            *hash ^= u64::from(*byte);
            *hash = hash.wrapping_mul(0x100000001b3);
        }
    }
    fn fold_length(hash: &mut u64, value: usize) {
        fold(hash, &(value as u64).to_le_bytes());
    }

    let mut hash = 0xcbf29ce484222325u64;
    let mut token_count = 0usize;
    let mut ids = source
        .active_content_ids()
        .map_err(|error| format!("{error:?}"))?;
    ids.sort();
    for id in ids {
        fold_length(&mut hash, id.len());
        fold(&mut hash, id.as_bytes());
        let Some(record) = source.record(&id).map_err(|error| format!("{error:?}"))? else {
            fold_length(&mut hash, 0);
            continue;
        };
        let tokens = corpus_kit::default_keyword_tokens(&record.text);
        fold_length(&mut hash, tokens.len());
        token_count += tokens.len();
        for token in tokens {
            fold_length(&mut hash, token.len());
            fold(&mut hash, token.as_bytes());
        }
    }
    Ok((format!("{hash:016x}"), token_count))
}

/// Raw-connection metrics probe (separate read connection; the estate's own
/// connection stays inside the coordinator's storage).
fn probe(path: &str, label: &str) {
    let conn = rusqlite::Connection::open(path).expect("probe open");
    let one = |sql: &str| -> i64 { conn.query_row(sql, [], |r| r.get(0)).unwrap_or(-1) };
    q(&format!("{label}.page_count"), one("PRAGMA page_count"));
    q(
        &format!("{label}.freelist_count"),
        one("PRAGMA freelist_count"),
    );
    q(&format!("{label}.page_size"), one("PRAGMA page_size"));
    for table in [
        "chunks",
        "corpus_metadata",
        "vectors",
        "iix_termfreqs",
        "iix_doclens",
        "drawers",
        "corpus_documents",
        "corpus_index_state",
    ] {
        let count = conn
            .query_row(&format!("SELECT count(*) FROM \"{table}\""), [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap_or(-1);
        q(&format!("{label}.rows.{table}"), count);
    }
    // Per-table bytes via dbstat (aggregated); tolerated to fail on builds
    // without the dbstat vtab.
    if let Ok(mut stmt) = conn.prepare(
        "SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY sum(pgsize) DESC LIMIT 12",
    ) {
        if let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
        {
            for row in rows.flatten() {
                q(&format!("{label}.bytes.{}", row.0), row.1);
            }
        }
    }
    // Per-provider/lane row census — the five-signal qualification's
    // headline shape.
    if let Ok(mut stmt) = conn
        .prepare("SELECT model_id, vector_index, count(*) FROM vectors GROUP BY 1, 2 ORDER BY 1, 2")
    {
        if let Ok(rows) = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        }) {
            for row in rows.flatten() {
                q(&format!("{label}.vectors.{}.lane{}", row.0, row.1), row.2);
            }
        }
    }
    if let Ok(mut stmt) = conn
        .prepare("SELECT model_id, count(*) FROM corpus_provider_coverage GROUP BY 1 ORDER BY 1")
    {
        if let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
        {
            for row in rows.flatten() {
                q(&format!("{label}.coverage.{}", row.0), row.1);
            }
        }
    }
    let file = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let wal = std::fs::metadata(format!("{path}-wal"))
        .map(|m| m.len())
        .unwrap_or(0);
    let shm = std::fs::metadata(format!("{path}-shm"))
        .map(|m| m.len())
        .unwrap_or(0);
    // Sidecar + queue siblings share the db file's directory.
    let stem = path.trim_end_matches(".sqlite");
    let vec_sidecar = std::fs::metadata(format!("{stem}.vectors.vec"))
        .map(|m| m.len())
        .unwrap_or(0);
    let mut dir_total = 0u64;
    if let Some(parent) = std::path::Path::new(path).parent() {
        if let Ok(entries) = std::fs::read_dir(parent) {
            let mut queue_bytes = 0u64;
            for entry in entries.flatten() {
                if let Ok(meta) = entry.metadata() {
                    if meta.is_file() {
                        dir_total += meta.len();
                        let name = entry.file_name().to_string_lossy().to_string();
                        if name.contains("queue") {
                            queue_bytes += meta.len();
                        }
                    }
                }
            }
            q(&format!("{label}.queue_bytes"), queue_bytes);
        }
    }
    q(&format!("{label}.file_bytes"), file);
    q(&format!("{label}.wal_bytes"), wal);
    q(&format!("{label}.shm_bytes"), shm);
    q(&format!("{label}.vec_sidecar_bytes"), vec_sidecar);
    q(&format!("{label}.estate_dir_bytes"), dir_total);
}

#[test]
#[ignore = "P6 qualification driver — needs MOOT_SCF_QUAL_DB pointing at a recoverable clone"]
fn qualify_large_estate_migration() {
    let Ok(path) = std::env::var("MOOT_SCF_QUAL_DB") else {
        eprintln!("MOOT_SCF_QUAL_DB not set — skipping");
        return;
    };
    let owner = std::env::var("MOOT_SCF_QUAL_OWNER").unwrap_or_else(|_| "mootx01-user".into());

    probe(&path, "before");

    let mut coord = EstateCoordinator::new();
    let t_open = Instant::now();
    let sqlite_store =
        SqliteDrawerStore::from_path(&path, NOW, None, 30.0).expect("SqliteDrawerStore::from_path");
    let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
    let storage: Arc<dyn Storage> = store.storage().expect("sqlite store exposes storage");
    let handle = coord
        .open(store, OwnerCredentials::new(&owner), 0, 100)
        .expect("open estate");
    q(
        "open_secs",
        format!("{:.2}", t_open.elapsed().as_secs_f64()),
    );

    // Migration (idempotent + resumable — a rerun after a kill resumes from
    // the persisted state and cursor).
    let t_mig = Instant::now();
    let report = coord
        .run_shared_content_migration(&handle, NOW, default_ensemble())
        .expect("migration");
    q(
        "migration_secs",
        format!("{:.2}", t_mig.elapsed().as_secs_f64()),
    );
    q("migration.state", format!("{:?}", report.state));
    q("migration.legacy_chunk_count", report.legacy_chunk_count);
    q(
        "migration.legacy_vector_key_count",
        report.legacy_vector_key_count,
    );
    q(
        "migration.rebuilt_content_count",
        report.rebuilt_content_count,
    );
    q(
        "migration.estimated_reclaimable_bytes",
        report.estimated_reclaimable_bytes.unwrap_or(-1),
    );
    if report.rebuilt_content_count > 0 && t_mig.elapsed().as_secs_f64() > 0.0 {
        q(
            "migration.index_throughput_per_sec",
            format!(
                "{:.1}",
                report.rebuilt_content_count as f64 / t_mig.elapsed().as_secs_f64()
            ),
        );
    }
    assert!(matches!(
        report.state,
        SharedContentMigrationState::ReclaimPending | SharedContentMigrationState::Complete
    ));

    probe(&path, "migrated");

    // Physical reclamation (WAL checkpoint + VACUUM) through the completion
    // hook — skipped (idempotent no-op) if a prior run already completed.
    let t_rec = Instant::now();
    let maintenance = coord
        .complete_shared_content_reclaim(&handle, NOW)
        .expect("reclaim");
    q(
        "reclaim_secs",
        format!("{:.2}", t_rec.elapsed().as_secs_f64()),
    );
    if let Some(m) = &maintenance {
        q("reclaim.performed", m.performed);
        q("reclaim.freelist_before", m.freelist_pages_before);
        q("reclaim.freelist_after", m.freelist_pages_after);
        q("reclaim.file_bytes_before", m.file_size_bytes_before);
        q("reclaim.file_bytes_after", m.file_size_bytes_after);
        q("reclaim.wal_bytes_before", m.wal_bytes_before);
        q("reclaim.wal_bytes_after", m.wal_bytes_after);
        q("reclaim.reclaimed_bytes", m.reclaimed_bytes);
    }
    let status = coord.shared_content_reclaim_status(&handle);
    q("status.state", format!("{:?}", status.state));
    q(
        "status.reclaimed_bytes",
        status.reclaimed_bytes.unwrap_or(-1),
    );

    probe(&path, "reclaimed");

    // Post-migration recall qualification: attached engine over the SAME
    // storage — BM25 hits must BE drawer IDs and hydrate directly.
    let estate = coord.estate_for(&handle).expect("estate").clone();
    let content_source = LocusDrawerContentSource::new(estate.clone());
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        CorpusContentConfiguration::new(
            CorpusOperatingMode::Attached,
            CorpusIndexUnitPolicy::WholeContent,
        )
        .expect("config"),
        Arc::new(LocusDrawerContentSource::new(estate.clone())),
        default_ensemble(),
    )
    .expect("engine");
    let (token_digest, token_count) =
        token_stream_fingerprint(&content_source).expect("token-stream fingerprint");
    q("recall.token_stream_fnv64", token_digest);
    q("recall.token_count", token_count);
    q(
        "recall.indexed_sources",
        engine.indexed_source_ids().map(|s| s.len()).unwrap_or(0),
    );
    q(
        "recall.coverage_attestations",
        engine
            .index_coverage_attestations()
            .map(|a| a.len())
            .unwrap_or(0),
    );
    // Per-provider coverage under the LIVE generations.
    for (model_id, digest) in engine.provider_generations() {
        q(
            &format!("recall.coverage.{model_id}"),
            engine.covered_count(&model_id).ok().flatten().unwrap_or(0),
        );
        q(&format!("recall.generation.{model_id}"), digest);
    }
    for (i, query) in [
        "project planning decisions",
        "release engineering process",
        "memory estate",
    ]
    .iter()
    .enumerate()
    {
        // Per-signal dense float lane: every configured signal must serve.
        let t_f = Instant::now();
        let per_signal = engine.float_nearest_per_signal(query, 5);
        q(
            &format!("recall.q{i}.float_all_signals_ms"),
            format!("{:.1}", t_f.elapsed().as_secs_f64() * 1000.0),
        );
        for (model_id, outcome) in &per_signal {
            let served = matches!(outcome, corpus_kit::FloatLaneOutcome::Hits(h) if !h.is_empty());
            q(&format!("recall.q{i}.float.{model_id}.served"), served);
        }
        let t_q = Instant::now();
        let hits = engine.bm25_top_k(query, 5).unwrap_or_default();
        q(
            &format!("recall.q{i}.latency_ms"),
            format!("{:.1}", t_q.elapsed().as_secs_f64() * 1000.0),
        );
        q(&format!("recall.q{i}.hits"), hits.len());
        if let Some((top_id, score)) = hits.first() {
            // Direct identity: the hit ID hydrates a Drawer with NO mapping.
            let hydrated = estate.drawer_by_id(top_id).ok().flatten().is_some();
            q(&format!("recall.q{i}.top_score"), format!("{score:.3}"));
            q(&format!("recall.q{i}.top_hydrates_directly"), hydrated);
        }
    }
}

/// Diagnostic probe: recompute the protected-vectors fold per model on a
/// database, printing per-model row counts + fold sums so a baseline/verify
/// mismatch can be localized. Env: MOOT_SCF_QUAL_DB (db), optional
/// MOOT_SCF_QUAL_EXCLUDE_MODEL (exclude rows under this model whose item is
/// in corpus_index_state — the verify-side exclusion).
#[test]
#[ignore = "diagnostic probe"]
fn probe_protected_fold() {
    use persistence_kit::TypedValue;
    let Ok(path) = std::env::var("MOOT_SCF_QUAL_DB") else {
        return;
    };
    let exclude_model = std::env::var("MOOT_SCF_QUAL_EXCLUDE_MODEL").ok();

    let sqlite_store = SqliteDrawerStore::from_path(&path, NOW, None, 30.0).expect("from_path");
    let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
    let storage: Arc<dyn Storage> = store.storage().expect("storage");

    // The verify-side "rebuilt" set (empty table on a pristine estate).
    let rebuilt: std::collections::BTreeSet<String> = storage
        .row_store()
        .query("corpus_index_state", None, &[], None, None)
        .map(|rows| {
            rows.iter()
                .filter_map(|r| match r.get("content_id") {
                    Some(TypedValue::Text(t)) => Some(t.clone()),
                    _ => None,
                })
                .filter(|id| !id.starts_with('\u{1F}'))
                .collect()
        })
        .unwrap_or_default();
    println!("PROBE rebuilt_count={}", rebuilt.len());

    // Baseline-side exclusion: the legacy vector keys from the migration
    // record when present (pristine estates have no record — empty set).
    let legacy: std::collections::BTreeSet<String> = storage
        .row_store()
        .query("glk_shared_content_migration", None, &[], None, None)
        .ok()
        .and_then(|rows| {
            rows.first().and_then(|r| match r.get("record") {
                Some(TypedValue::Blob(b)) => serde_json::from_slice::<serde_json::Value>(b)
                    .ok()
                    .and_then(|v| v.get("legacyVectorKeys").cloned())
                    .and_then(|v| serde_json::from_value::<Vec<String>>(v).ok()),
                Some(TypedValue::Json(b)) => serde_json::from_slice::<serde_json::Value>(b)
                    .ok()
                    .and_then(|v| v.get("legacyVectorKeys").cloned())
                    .and_then(|v| serde_json::from_value::<Vec<String>>(v).ok()),
                _ => None,
            })
        })
        .map(|v| v.into_iter().collect())
        .unwrap_or_default();
    println!("PROBE legacy_keys={}", legacy.len());

    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let excluded_cols: std::collections::BTreeSet<String> =
        ["id"].iter().map(|s| s.to_string()).collect();
    let mut per_model: std::collections::BTreeMap<String, (usize, u64)> =
        std::collections::BTreeMap::new();
    for row in &rows {
        let (
            Some(TypedValue::Text(item_id)),
            Some(TypedValue::Int(vector_index)),
            Some(TypedValue::Text(model_id)),
        ) = (
            row.get("item_id"),
            row.get("vector_index"),
            row.get("model_id"),
        )
        else {
            println!(
                "PROBE row_with_unexpected_forms item_id={:?} vector_index={:?} model_id={:?}",
                row.get("item_id"),
                row.get("vector_index"),
                row.get("model_id")
            );
            continue;
        };
        let key = format!("{item_id}|{vector_index}|{model_id}");
        if legacy.contains(&key) {
            continue;
        }
        if let Some(m) = &exclude_model {
            if m == model_id && rebuilt.contains(item_id) {
                continue;
            }
        }
        let encoded =
            persistence_kit::database_inventory::canonical_row_encoding(row, &excluded_cols);
        let hash = persistence_kit::layout_signature::fnv1a64_fold(
            encoded.as_bytes(),
            persistence_kit::layout_signature::FNV1A64_OFFSET_BASIS,
        );
        let entry = per_model.entry(model_id.clone()).or_insert((0, 0));
        entry.0 += 1;
        entry.1 = entry.1.wrapping_add(hash);
    }
    let mut combined: u64 = 0;
    for (model, (count, sum)) in &per_model {
        println!("PROBE model={model} rows={count} foldsum={sum:016x}");
        combined = combined.wrapping_add(*sum);
    }
    println!("PROBE combined={combined:016x}");
}
