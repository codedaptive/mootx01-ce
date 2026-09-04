//! drain_worker_ownership_tests.rs — the drain worker never owns its engine.
//!
//! Releasing the last host `Arc` of a mounted `CorpusContentEngine` (or a
//! legacy `Corpus`) runs `Drop`, which stops and joins the worker: no thread
//! outlives the engine, so nothing is indexed under an engine no host can
//! reach any more. A host that skips `drop_ingest_queue` gets the same
//! teardown the explicit path gives. Mirrors Swift
//! `DrainWorkerOwnershipTests`.

use corpus_kit::{
    Corpus, CorpusContentConfiguration, CorpusContentEngine, CorpusContentSource,
    CorpusDocumentStore, CorpusIndexUnitPolicy, CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};
use uuid::Uuid;

/// Poll until `done` holds or `limit` elapses. The worker releases its
/// per-pass handle within one poll interval plus the pass itself, so a
/// generous limit keeps the assertion free of scheduling noise.
fn eventually(limit: Duration, done: impl Fn() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < limit {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    done()
}

/// RAII temp-dir cleanup.
struct TempDir(std::path::PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch_sqlite() -> (Arc<dyn Storage>, TempDir) {
    let dir = std::env::temp_dir().join(format!("corpuskit-drain-ownership-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("estate.sqlite3").to_string_lossy().into_owned();
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path,
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(config).expect("open sqlite"));
    (storage, TempDir(dir))
}

fn engine_over(storage: Arc<dyn Storage>) -> Arc<CorpusContentEngine> {
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .expect("content schema");
    let source = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    Arc::new(
        CorpusContentEngine::open(
            storage,
            CorpusContentConfiguration::new(
                CorpusOperatingMode::Standalone,
                CorpusIndexUnitPolicy::WholeContent,
            )
            .expect("configuration"),
            source as Arc<dyn CorpusContentSource>,
            vec![EmbeddingModelConfig::Deterministic],
            false,
        )
        .expect("engine"),
    )
}

#[test]
fn a_released_engine_with_a_mounted_queue_drops() {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let engine = engine_over(storage);
    engine.mount_ingest_queue().expect("mount");
    let weak: Weak<CorpusContentEngine> = Arc::downgrade(&engine);
    drop(engine);
    assert!(
        eventually(Duration::from_secs(5), || weak.upgrade().is_none()),
        "the drain worker must not keep the engine alive after its last host reference is released"
    );
}

#[test]
fn a_released_engine_releases_its_encode_lease() {
    // SQLite estate: the worker holds the "encode" lease file beside the
    // estate while it runs and removes it on its way out, so the file is the
    // observable proof that the thread left through its clean exit path.
    let (storage, dir) = scratch_sqlite();
    let lease = dir.0.join("encode.drain.lease");
    let engine = engine_over(storage);
    engine.mount_ingest_queue().expect("mount");
    assert!(
        eventually(Duration::from_secs(5), || lease.exists()),
        "the worker acquires the lease on its first pass"
    );
    let weak = Arc::downgrade(&engine);
    drop(engine);
    assert!(eventually(Duration::from_secs(5), || weak.upgrade().is_none()));
    assert!(
        eventually(Duration::from_secs(5), || !lease.exists()),
        "the worker releases the lease when it exits"
    );
}

#[test]
fn a_released_legacy_corpus_with_a_mounted_queue_drops() {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let corpus = Arc::new(
        Corpus::open(storage, EmbeddingModelConfig::Deterministic).expect("corpus"),
    );
    corpus.mount_ingest_queue().expect("mount");
    let weak: Weak<Corpus> = Arc::downgrade(&corpus);
    drop(corpus);
    assert!(
        eventually(Duration::from_secs(5), || weak.upgrade().is_none()),
        "the encode and import workers must not keep the corpus alive"
    );
}

#[test]
fn explicit_teardown_then_release_runs_both_paths_without_incident() {
    // The explicit teardown and the `Drop` safety net both run; the second
    // finds nothing mounted and is a no-op.
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let engine = engine_over(storage);
    engine.mount_ingest_queue().expect("mount");
    engine.drop_ingest_queue();
    let weak = Arc::downgrade(&engine);
    drop(engine);
    assert!(weak.upgrade().is_none());
}
