//! Mission 6a-ii-β: cross-port conformance for the basis-persistence +
//! training lifecycle (single provider).
//!
//! Mirrors the Swift `BasisPersistence` suite. The load-bearing test is the
//! persist → reopen → embed proof: ingest a FIXED corpus with a trainable RI
//! provider, `reindex` (train + persist a fresh basis), close, reopen over the
//! SAME on-disk SQLite file (load-on-open reconstructs the trained provider),
//! and embed a FIXED query. The persisted basis blob must equal the α canonical
//! blob BYTE-FOR-BYTE and the reopened embedding must equal the α canonical
//! "car engine" bit patterns — the SAME shared fixture the Swift leg is
//! canonical for. This proves persist → reopen → embed is cross-port
//! deterministic.
//!
//! Real SQLite (file-backed), never InMemory: the persist→reopen path must
//! exercise genuine primitive-form read-back (a TIMESTAMP column round-trips as
//! a parsed `Timestamp(i64)` here), the same discipline as bundle_store_tests.

use corpus_kit::{BasisStore, Corpus, EmbeddingModelConfig, PersistedBasis};
use corpus_kit_providers::RandomIndexingProvider;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use serde::Deserialize;
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

// Process-wide lock: Corpus.ingest / reindex emit IntellectusLib telemetry, and
// the SQLite scratch files must not race. Shared discipline with corpus_tests.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

/// The five α RI docs as raw single-chunk texts. `default_keyword_tokens`
/// tokenizes each back to the α token arrays, so training on these reproduces
/// the α basis exactly. A short single-sentence doc yields one chunk whose text
/// equals the doc, so the chunk texts trained on equal the α corpus.
const RI_DOCS: [&str; 5] = [
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
];

const NOW_MILLIS: i64 = 1_700_000_000_000;

/// A unique on-disk SQLite path.
fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-basis-rust-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

/// Open a SqliteStorage over `path`. A SECOND open over the same path reopens
/// the persisted file — the load-on-open path.
fn storage_at(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    Arc::new(SqliteStorage::new(config).expect("open sqlite"))
}

fn fresh_ri_corpus(storage: Arc<dyn Storage>) -> Corpus {
    Corpus::open(
        storage,
        EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        },
    )
    .expect("Corpus::open must succeed")
}

/// The shared alpha fixture pins the historical 1.0 provider envelope. Keep
/// that fixture useful while production defaults advance to 1.1 to invalidate
/// bases trained with the pre-correction tokenizer contract.
fn legacy_ri_corpus(storage: Arc<dyn Storage>) -> Corpus {
    Corpus::open(
        storage,
        EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::with_parameters(
                "random-indexing-v1",
                "1.0.0",
                corpus_kit_providers::RI_PROJECTION_SEED,
            )),
        },
    )
    .expect("Corpus::open legacy fixture provider must succeed")
}

// ── §2 reindex persists a basis ──

#[test]
fn reindex_persists_basis() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = fresh_ri_corpus(storage_at(&path));
    for (i, doc) in RI_DOCS.iter().enumerate() {
        corpus
            .ingest(doc, &format!("doc-{i}"), NOW_MILLIS)
            .expect("ingest");
    }
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let store = BasisStore::new(storage_at(&path));
    let loaded = store
        .load("random-indexing-v1", "1.1.0")
        .expect("load")
        .expect("basis row must exist after reindex");
    assert_eq!(loaded.trained_chunk_count, RI_DOCS.len());
}

// ── §3 first-ingest auto-train ──

#[test]
fn first_ingest_auto_trains_and_persists() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = fresh_ri_corpus(storage_at(&path));
    let store = BasisStore::new(storage_at(&path));

    assert!(
        store.load("random-indexing-v1", "1.1.0").expect("load").is_none(),
        "no basis before first ingest"
    );

    corpus.ingest(RI_DOCS[0], "doc-0", NOW_MILLIS).expect("ingest 0");
    let after_first = store
        .load("random-indexing-v1", "1.1.0")
        .expect("load")
        .expect("basis after first ingest");
    let count_after_first = after_first.trained_chunk_count;

    // A SECOND ingest must NOT retrain — the basis row (chunk count) is unchanged.
    corpus.ingest(RI_DOCS[1], "doc-1", NOW_MILLIS).expect("ingest 1");
    let after_second = store
        .load("random-indexing-v1", "1.1.0")
        .expect("load")
        .expect("basis after second ingest");
    assert_eq!(after_second.trained_chunk_count, count_after_first);
}

// ── §5 lifecycle ──

#[test]
fn destroy_recall_index_wipes_basis() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = fresh_ri_corpus(storage_at(&path));
    for (i, doc) in RI_DOCS.iter().enumerate() {
        corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest");
    }
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let store = BasisStore::new(storage_at(&path));
    assert!(store.load("random-indexing-v1", "1.1.0").expect("load").is_some());

    corpus.destroy_recall_index().expect("destroy");
    assert!(
        store.load("random-indexing-v1", "1.1.0").expect("load").is_none(),
        "destroy must wipe the basis row (no orphans)"
    );
}

#[test]
fn non_trainable_persists_no_basis() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = Corpus::open(storage_at(&path), EmbeddingModelConfig::Deterministic)
        .expect("Corpus::open");
    corpus.ingest("car engine drive", "doc-0", NOW_MILLIS).expect("ingest");
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let store = BasisStore::new(storage_at(&path));
    assert!(
        store.load("corpus-deterministic-v1", "1.0.0").expect("load").is_none(),
        "non-trainable provider persists no basis"
    );
}

// ── §6 cross-port conformance: persist → reopen → embed ──

/// The α RI canonical fixture: trained-basis blob + per-probe embedding bits.
/// Embedded with `include_bytes!` (hermetic). Swift is the canonical source;
/// this Rust leg asserts byte/bit-identity against the SAME shared fixture.
const RI_FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/ri_basis_blob.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RiBasisFixture {
    blob_base64: String,
    embeddings: Vec<FixtureEmbedding>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureEmbedding {
    text: String,
    float_bits: Vec<u32>,
}

/// Inline base64 decoder (C-1: no external crate). Mirrors the providers'
/// `basis_fixture::decode_base64` shape; standard alphabet, '=' padding.
fn decode_base64(s: &str) -> Vec<u8> {
    fn val(c: u8) -> i32 {
        match c {
            b'A'..=b'Z' => (c - b'A') as i32,
            b'a'..=b'z' => (c - b'a' + 26) as i32,
            b'0'..=b'9' => (c - b'0' + 52) as i32,
            b'+' => 62,
            b'/' => 63,
            _ => -1,
        }
    }
    let mut out = Vec::new();
    let mut buf = 0i32;
    let mut bits = 0;
    for &c in s.as_bytes() {
        if c == b'=' {
            break;
        }
        let v = val(c);
        if v < 0 {
            continue;
        }
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    out
}

#[test]
fn cross_port_persist_reopen_embed() {
    let _g = global_lock();
    let fixture: RiBasisFixture =
        serde_json::from_slice(RI_FIXTURE).expect("ri_basis_blob.json valid");
    let expected_blob = decode_base64(&fixture.blob_base64);
    let probe = "car engine";
    let expected_bits = &fixture
        .embeddings
        .iter()
        .find(|e| e.text == probe)
        .expect("fixture must contain 'car engine' embedding")
        .float_bits;

    let path = scratch_path();

    // Ingest the FIXED α corpus, reindex to train+persist a fresh basis on the
    // chunk texts, then assert the persisted blob is the α canonical blob
    // byte-for-byte. Training fresh (reconstruct from the empty blob) makes the
    // basis the canonical from-scratch one, matching the Swift port.
    {
        let corpus = legacy_ri_corpus(storage_at(&path));
        for (i, doc) in RI_DOCS.iter().enumerate() {
            corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest");
        }
        corpus.reindex(NOW_MILLIS).expect("reindex");

        let store = BasisStore::new(storage_at(&path));
        let persisted: PersistedBasis = store
            .load("random-indexing-v1", "1.0.0")
            .expect("load")
            .expect("basis row");
        assert_eq!(
            persisted.basis, expected_blob,
            "persisted basis blob must equal the α canonical blob byte-for-byte"
        );
    }

    // Reopen over the SAME on-disk file — load-on-open reconstructs the trained
    // provider from the persisted basis. The reopened corpus's embedding of the
    // fixed probe must equal the α canonical bit patterns. This proves
    // persist → reopen → embed is cross-port deterministic.
    let reopened = legacy_ri_corpus(storage_at(&path));
    let after = reopened.embed_float(probe).expect("embed_float");
    let after_bits: Vec<u32> = after.iter().map(|f| f.to_bits()).collect();
    assert_eq!(
        &after_bits, expected_bits,
        "reopened embedding must equal the α canonical 'car engine' bit patterns"
    );
}

// ── §7 maintained counts wiring (incremental-counts change set, P3) ──

use corpus_kit::corpus_provider_counts_store::CorpusProviderCountsStore;

const RI_MODEL_ID: &str = "random-indexing-v1";
const RI_MODEL_VERSION: &str = "1.1.0";

#[test]
fn ingest_persists_counts_with_growing_anchor() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = fresh_ri_corpus(storage_at(&path));
    let counts = CorpusProviderCountsStore::new(storage_at(&path));

    // No counts row before any ingest.
    assert!(counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .is_none());

    corpus.ingest(RI_DOCS[0], "doc-0", NOW_MILLIS).expect("ingest 0");
    let a0 = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("ingest must persist a counts row");
    assert_eq!(a0.document_count, 1);
    assert!(a0.vocab_size > 0);

    // A second ingest with new vocabulary grows both anchors.
    corpus.ingest(RI_DOCS[3], "doc-3", NOW_MILLIS).expect("ingest 3");
    let a1 = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");
    assert_eq!(a1.document_count, 2);
    assert!(
        a1.vocab_size > a0.vocab_size,
        "new-vocabulary doc must grow the vocab anchor"
    );
}

#[test]
fn reopen_restores_counts_anchor() {
    let _g = global_lock();
    let path = scratch_path();
    {
        let corpus = fresh_ri_corpus(storage_at(&path));
        for (i, doc) in RI_DOCS.iter().enumerate() {
            corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest");
        }
    }
    let counts = CorpusProviderCountsStore::new(storage_at(&path));
    let before = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");
    assert_eq!(before.document_count, RI_DOCS.len());

    // Reopen and ingest ONE more document. A reset accumulator would read 1;
    // a restored one continues from the persisted anchor.
    let reopened = fresh_ri_corpus(storage_at(&path));
    reopened
        .ingest("airplane wing flight sky", "doc-new", NOW_MILLIS)
        .expect("ingest new");
    let after = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");
    assert_eq!(
        after.document_count,
        RI_DOCS.len() + 1,
        "reopened accumulator must continue from the restored doc count, not reset"
    );
}

#[test]
fn reopened_corpus_retrains_on_reindex() {
    let _g = global_lock();
    let path = scratch_path();
    {
        let corpus = fresh_ri_corpus(storage_at(&path));
        for (i, doc) in RI_DOCS.iter().enumerate() {
            corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest");
        }
        corpus.reindex(NOW_MILLIS).expect("reindex");
    }
    let store = BasisStore::new(storage_at(&path));
    assert_eq!(
        store
            .load(RI_MODEL_ID, RI_MODEL_VERSION)
            .expect("load")
            .expect("basis row")
            .trained_chunk_count,
        RI_DOCS.len()
    );

    // Reopen, add a doc, reindex. Before the frozen-after-restart fix the reopened
    // corpus dropped its empty-basis factory and reindex could only re-embed —
    // the basis stayed trained on 5 chunks. With the factory retained, reindex
    // retrains from scratch on the full 6-chunk corpus.
    let reopened = fresh_ri_corpus(storage_at(&path));
    reopened
        .ingest("airplane wing flight sky", "doc-new", NOW_MILLIS)
        .expect("ingest new");
    reopened.reindex(NOW_MILLIS).expect("reindex");

    assert_eq!(
        store
            .load(RI_MODEL_ID, RI_MODEL_VERSION)
            .expect("load")
            .expect("basis row")
            .trained_chunk_count,
        RI_DOCS.len() + 1,
        "reopened corpus must retrain on the full corpus (incl. the new doc)"
    );
}

#[test]
fn reingest_does_not_inflate_counts() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = fresh_ri_corpus(storage_at(&path));
    let counts = CorpusProviderCountsStore::new(storage_at(&path));

    for (i, doc) in RI_DOCS.iter().enumerate() {
        corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest");
    }
    let chunk_count0 = corpus.count().expect("count");
    let a0 = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");
    assert_eq!(a0.document_count, RI_DOCS.len());

    // Re-ingest the IDENTICAL sources: same text + source_id → same
    // content-addressed chunk ids → idempotent no-op in the bundle store. The
    // maintained counts must NOT advance — the fold runs only over newly-inserted
    // chunks, of which there are none on the second pass.
    for (i, doc) in RI_DOCS.iter().enumerate() {
        corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("re-ingest");
    }
    let chunk_count1 = corpus.count().expect("count");
    let a1 = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");

    assert_eq!(chunk_count1, chunk_count0, "re-ingest must not add chunks (idempotent)");
    assert_eq!(
        a1.document_count, a0.document_count,
        "re-ingest must not inflate the maintained document count"
    );
    assert_eq!(
        a1.vocab_size, a0.vocab_size,
        "re-ingest must not inflate the maintained vocabulary anchor"
    );
}

#[test]
fn reingest_batch_does_not_inflate_counts() {
    let _g = global_lock();
    let path = scratch_path();
    let corpus = fresh_ri_corpus(storage_at(&path));
    let counts = CorpusProviderCountsStore::new(storage_at(&path));

    let batch: Vec<(String, String, i64)> = RI_DOCS
        .iter()
        .enumerate()
        .map(|(i, d)| (d.to_string(), format!("doc-{i}"), NOW_MILLIS))
        .collect();
    corpus.ingest_batch(&batch).expect("ingest_batch");
    let chunk0 = corpus.count().expect("count");
    let a0 = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");
    assert_eq!(a0.document_count, RI_DOCS.len());

    // Re-import the IDENTICAL batch via the drain path: every chunk is an
    // idempotent no-op, so the maintained counts must not advance.
    corpus.ingest_batch(&batch).expect("re-ingest_batch");
    let a1 = counts
        .growth_anchor(RI_MODEL_ID, RI_MODEL_VERSION)
        .expect("growth_anchor")
        .expect("counts row");

    assert_eq!(corpus.count().expect("count"), chunk0, "batch re-import must not add chunks");
    assert_eq!(
        a1.document_count, a0.document_count,
        "batch re-import must not inflate the maintained document count"
    );
    assert_eq!(
        a1.vocab_size, a0.vocab_size,
        "batch re-import must not inflate the maintained vocabulary anchor"
    );
}

// a file-backed (SQLite) estate persists the Corpus
// ingest queue to a per-estate SQLite file BESIDE the estate — not a plaintext
// maildir. The sibling filename is `<estate-stem>.queue.sqlite` so two estates
// in the same directory never share a queue (cross-estate isolation). Proven by:
//   1. `<estate-stem>.queue.sqlite` appears as a regular FILE beside the estate db.
//   2. No `corpus_ingest_queue/` maildir is created (old FilesystemBackend path is gone).
//   3. The enqueued document is searchable via the per-estate queue path.
// Mirrors Swift's ingestQueueIsDurableForSQLiteEstate (T4 rewrite).
#[test]
fn ingest_queue_is_durable_for_sqlite_estate() {
    let path = scratch_path();
    let corpus = Arc::new(
        Corpus::open(storage_at(&path), EmbeddingModelConfig::Deterministic)
            .expect("Corpus::open must succeed"),
    );
    corpus
        .enqueue_ingest("durable queue content survives restart", "doc-queue", NOW_MILLIS)
        .expect("enqueue_ingest");
    corpus.await_ingest_drain().expect("await_ingest_drain");

    // T4: derive the per-estate sibling path the same way EstateConfiguration does:
    // <dir>/<estate-stem>.queue.sqlite — guarantees cross-estate isolation.
    let estate_path = std::path::Path::new(&path);
    let stem = estate_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let sibling_filename = format!("{}.queue.sqlite", stem);
    let queue_sibling = estate_path
        .parent()
        .map(|p| p.join(&sibling_filename))
        .unwrap_or_else(|| std::path::PathBuf::from(&sibling_filename));

    assert!(
        queue_sibling.is_file(),
        "{} must exist as a regular file beside the estate db (T4 per-estate isolation)",
        sibling_filename
    );

    // T4: the old plaintext maildir must NOT exist.
    let mut old_maildir = std::path::PathBuf::from(&path);
    old_maildir.pop();
    old_maildir.push("corpus_ingest_queue");
    assert!(
        !old_maildir.exists(),
        "corpus_ingest_queue/ maildir must NOT exist (old FilesystemBackend path is gone in T4)"
    );

    // The enqueued document is searchable via the per-estate queue path.
    let results = corpus.recall("durable queue", 5, NOW_MILLIS).expect("recall");
    assert!(!results.is_empty());

    let _ = std::fs::remove_file(&queue_sibling);
    let _ = std::fs::remove_file(&path);
}
