//! The open-path format-version gate: an estate whose persisted basis and
//! counts rows were written by another codec generation (same provider magic,
//! another format-version byte) must
//!
//!   1. open without error — the estate stays usable;
//!   2. serve the affected slot UNTRAINED (the float lane reports the
//!      structural opt-out, never vectors pooled the old way against queries
//!      pooled the new way);
//!   3. refuse to restore the stale counts (`restore_counts_into` returns
//!      `Ok(false)`, the same contract as the invalidation sentinel);
//!   4. republish current-format basis and counts rows on the next retrain,
//!      after which the float lane serves again.
//!
//! The stale rows are produced by rewriting a freshly trained estate's rows
//! with the version byte changed — the shape a pre-bump estate presents to
//! this build. Swift twin: Tests/CorpusKitTests/BasisFormatGateTests.swift

use corpus_kit::basis_blob_frame;
use corpus_kit::corpus_provider_counts_store::{CorpusProviderCountsStore, PersistedCounts};
use corpus_kit::{BasisStore, Corpus, EmbeddingModelConfig, FloatLaneOutcome, PersistedBasis};
use corpus_kit_providers::{RandomIndexingProvider, BASIS_FORMAT_VERSION};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

const DOCS: [&str; 5] = [
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
];
const NOW_MILLIS: i64 = 1_700_000_000_000;
const MODEL_ID: &str = "random-indexing-v1";
const MODEL_VERSION: &str = "1.1.0";

fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-format-gate-rust-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

/// Real SQLite, so the persist → reopen path reads the rows back the way an
/// estate on disk presents them.
fn storage_at(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path: path.to_string(), busy_timeout_secs: 5.0 },
    );
    Arc::new(SqliteStorage::new(config).expect("open sqlite"))
}

fn ri_corpus(storage: Arc<dyn Storage>) -> Corpus {
    Corpus::open(
        storage,
        EmbeddingModelConfig::RandomIndexing { provider: Box::new(RandomIndexingProvider::new()) },
    )
    .expect("Corpus::open")
}

#[test]
fn frame_staleness_rule() {
    let current = [b"RIB1".as_slice(), &[BASIS_FORMAT_VERSION]].concat();
    let stale = [b"RIB1".as_slice(), &[BASIS_FORMAT_VERSION.wrapping_sub(1)], &[0, 1, 2]].concat();
    assert!(basis_blob_frame::is_stale_version(&stale, &current));
    assert!(!basis_blob_frame::is_stale_version(&current, &current));
    // A keying error (other magic) is corruption for the decoder, not skew.
    assert!(!basis_blob_frame::is_stale_version(b"PPB1\x01", &current));
    // Too short to frame: never stale (the decoder reports the truncation).
    assert!(!basis_blob_frame::is_stale_version(b"RIB", &current));
    assert_eq!(basis_blob_frame::format_version(&current), Some(BASIS_FORMAT_VERSION));
}

#[test]
fn stale_format_opens_untrained_and_reindex_republishes() {
    let _g = global_lock();
    let path = scratch_path();

    // 1. Train and persist a current-format basis + counts.
    {
        let corpus = ri_corpus(storage_at(&path));
        for (i, doc) in DOCS.iter().enumerate() {
            corpus.ingest(doc, &format!("doc-{i}"), NOW_MILLIS).expect("ingest");
        }
        corpus.reindex(NOW_MILLIS).expect("reindex");
        assert!(
            matches!(corpus.float_nearest("car engine", 3), FloatLaneOutcome::Hits(_)),
            "a trained corpus must serve the float lane"
        );
    }

    // 2. Rewrite both rows under the previous format version — the shape an
    //    estate written by the earlier codec presents.
    let stale_version = BASIS_FORMAT_VERSION.wrapping_sub(1);
    {
        let storage = storage_at(&path);
        let basis_store = BasisStore::new(Arc::clone(&storage));
        let persisted = basis_store
            .load(MODEL_ID, MODEL_VERSION)
            .expect("load")
            .expect("basis row");
        let mut basis = persisted.basis.clone();
        basis[4] = stale_version;
        basis_store
            .upsert(&PersistedBasis {
                model_id: MODEL_ID.to_string(),
                model_version: MODEL_VERSION.to_string(),
                basis,
                trained_at_secs: persisted.trained_at_secs,
                trained_chunk_count: persisted.trained_chunk_count,
            })
            .expect("upsert stale basis");

        let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
        let counts = counts_store
            .load(MODEL_ID, MODEL_VERSION)
            .expect("load counts")
            .expect("counts row");
        let mut stale_counts = counts.counts.clone();
        stale_counts[4] = stale_version;
        counts_store
            .upsert(&PersistedCounts {
                model_id: MODEL_ID.to_string(),
                model_version: MODEL_VERSION.to_string(),
                counts: stale_counts,
                document_count: counts.document_count,
                vocab_size: counts.vocab_size,
                updated_at_secs: counts.updated_at_secs,
            })
            .expect("upsert stale counts");

        // 3. The counts gate on its own: a fresh provider refuses the stale
        //    row with Ok(false) (the sentinel contract), not an error.
        let mut fresh = RandomIndexingProvider::new();
        let restored = counts_store
            .restore_counts_into(&mut fresh, MODEL_ID, MODEL_VERSION)
            .expect("restore must not error on a stale frame");
        assert!(!restored, "a stale-format counts row restores as 'no counts'");
    }

    // Reopen over the same file: the slot must open untrained.
    let reopened = ri_corpus(storage_at(&path));
    let outcome = reopened.float_nearest("car engine", 3);
    assert!(
        matches!(outcome, FloatLaneOutcome::UnavailableProviderOptOut),
        "a stale-format basis must open the slot untrained (provider opt-out); got {outcome:?}"
    );

    // 4. The retrain republishes current-format rows and the lane serves.
    reopened.reindex(NOW_MILLIS).expect("reindex after stale open");
    let storage = storage_at(&path);
    let republished = BasisStore::new(Arc::clone(&storage))
        .load(MODEL_ID, MODEL_VERSION)
        .expect("load")
        .expect("basis row");
    assert_eq!(
        basis_blob_frame::format_version(&republished.basis),
        Some(BASIS_FORMAT_VERSION),
        "reindex must republish the basis in the current format"
    );
    let counts_after = CorpusProviderCountsStore::new(storage)
        .load(MODEL_ID, MODEL_VERSION)
        .expect("load counts")
        .expect("counts row");
    assert_eq!(
        basis_blob_frame::format_version(&counts_after.counts),
        Some(BASIS_FORMAT_VERSION),
        "reindex must republish the counts in the current format"
    );
    assert!(
        matches!(reopened.float_nearest("car engine", 3), FloatLaneOutcome::Hits(_)),
        "after the retrain the float lane must serve again"
    );
}
