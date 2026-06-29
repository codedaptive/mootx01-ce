//! crash_recovery_reclaim_tests.rs — Mission #54 Part B/D:
//! On-mount crash-recovery GC and Corpus Drop idempotency for the Rust port.
//!
//! Mirrors Swift's CrashRecoveryReclaimTests.swift.
//!
//! Success criteria:
//!   1. Orphaned cur reclaim on mount: cur rows for the encode stream are reset
//!      to "new" (and subsequently drained) when the prior drainer's lease is stale.
//!   2. Live-drainer anti-yank (negative): a fresh lease blocks reclaim — the
//!      mounting corpus does NOT reset the live drainer's cur rows.
//!   3. Corpus Drop idempotency (Part D): drop_ingest_queue() is safe to call
//!      twice; the Drop impl calls it once and a manual call is harmless.
//!
//! Uses real on-disk SQLite (per-test temp dir) for DrainLease file interaction.
//! InMemoryStorage estates skip the DrainLease and crash recovery entirely (by
//! design — in-memory estates are single-process and cannot crash cross-process).

use corpus_kit::{Corpus, EmbeddingModelConfig};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use std::{path::PathBuf, time::SystemTime};
use uuid::Uuid;

// Process-wide lock: mirrors corpus_tests.rs discipline.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

const NOW_MILLIS: i64 = 1_500_000_000_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// RAII temp-dir cleanup — removes the directory when dropped.
struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Create a per-test temp dir and return (storage, TempDir guard, sqlite_path).
/// The estate SQLite file is at `<tmpdir>/estate-<uuid>.sqlite3`.
/// The DrainLease file lands beside it as `encode.drain.lease`.
fn make_scratch_storage() -> (Arc<dyn Storage>, TempDir, String) {
    let dir = std::env::temp_dir()
        .join(format!("corpuskit-reclaim-rust-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let sqlite_path = dir
        .join(format!("estate-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: sqlite_path.clone(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(config).expect("open sqlite"));
    (storage, TempDir(dir), sqlite_path)
}

/// Write a stale DrainLease file: owner = "dead-drainer", heartbeat = 20 s ago.
/// This simulates a crashed prior drainer whose lease is past the 15 s TTL.
fn write_stale_encode_lease(estate_dir: &PathBuf) {
    let stale_epoch = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
        - 20.0;   // 20 s ago — past 15 s TTL
    let lease_path = estate_dir.join("encode.drain.lease");
    let text = format!("pid-99999-dead-drainer\n{}\n", stale_epoch);
    std::fs::write(&lease_path, text).expect("write stale lease");
}

/// Write a FRESH DrainLease file (heartbeat = now) to simulate a live drainer.
fn write_fresh_encode_lease(estate_dir: &PathBuf, owner: &str) {
    let now_epoch = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let lease_path = estate_dir.join("encode.drain.lease");
    let text = format!("{}\n{}\n", owner, now_epoch);
    std::fs::write(&lease_path, text).expect("write fresh lease");
}

/// Make an Arc<Corpus> backed by the given storage.
fn make_corpus(storage: Arc<dyn Storage>) -> Arc<Corpus> {
    Arc::new(
        Corpus::open(storage, EmbeddingModelConfig::Deterministic)
            .expect("Corpus::open must succeed"),
    )
}

// ---------------------------------------------------------------------------
// 1. Orphaned cur reclaim on mount
// ---------------------------------------------------------------------------

/// Simulate a crashed drainer:
///   (a) create corpus1, mount its queue, enqueue and drain one job (now "cur"),
///   (b) write a stale lease (simulating a crash),
///   (c) drop corpus1 without completing the job (orphan the cur row),
///   (d) create corpus2 on the same estate,
///   (e) verify the orphaned cur row is reclaimed and eventually ingested.
#[test]
fn orphaned_cur_reclaimed_on_mount() {
    let _guard = global_lock();
    let (storage, _temp_dir, _sqlite_path) = make_scratch_storage();
    let estate_dir = {
        // Derive the estate dir from the sqlite path: its parent.
        let cfg = storage.configuration();
        match &cfg.backend {
            BackendConfiguration::Sqlite { path, .. } =>
                std::path::Path::new(path)
                    .parent()
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| std::path::PathBuf::from(".")),
            _ => std::path::PathBuf::from("."),
        }
    };

    // ── Phase 1: enqueue and orphan a "cur" job ──────────────────────────────

    let corpus1 = make_corpus(Arc::clone(&storage));
    corpus1.mount_ingest_queue().expect("mount queue");
    corpus1
        .enqueue_ingest("vanadium steel alloy heat treatment", "orphan-doc", NOW_MILLIS)
        .expect("enqueue");

    // Give the drain worker time to claim the job (→ cur).
    std::thread::sleep(std::time::Duration::from_millis(150));

    // Write a stale lease to make corpus2 think the prior drainer is dead.
    write_stale_encode_lease(&estate_dir);

    // Drop corpus1 WITHOUT completing the job — the cur row is orphaned.
    corpus1.drop_ingest_queue();

    // ── Phase 2: corpus2 mounts, sees stale lease, reclaims, and ingests ─────

    let corpus2 = make_corpus(Arc::clone(&storage));
    corpus2.mount_ingest_queue().expect("mount queue 2");

    // Wait for the drain worker to reclaim and ingest the orphaned job.
    corpus2.await_ingest_drain().expect("await drain");

    // Verify the job was re-ingested and is now recallable.
    let hits = corpus2
        .recall("vanadium steel heat treatment", 5, NOW_MILLIS)
        .expect("recall");
    assert!(
        !hits.is_empty(),
        "reclaimed orphaned job must be ingested and recallable by corpus2"
    );

    corpus2.drop_ingest_queue();
}

// ---------------------------------------------------------------------------
// 2. Live-drainer anti-yank (negative)
// ---------------------------------------------------------------------------

/// With a FRESH lease held by another "drainer", a second Corpus must NOT
/// reclaim that drainer's cur rows. We verify via in_flight() on the PK backend:
/// the cur row stays cur for the observation window.
#[test]
fn live_drainer_fresh_lease_blocks_reclaim() {
    use persistence_kit::SqliteStorage as Sq;
    use queuekit::{HLC, Job, JobId, QueueBackend, StreamId};
    use queuekit::persistencekit::PersistenceKitBackend;
    use serde_json::Map;

    let _guard = global_lock();
    let (storage, _temp_dir, _sqlite_path) = make_scratch_storage();
    let estate_dir = {
        let cfg = storage.configuration();
        match &cfg.backend {
            BackendConfiguration::Sqlite { path, .. } =>
                std::path::Path::new(path)
                    .parent()
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| std::path::PathBuf::from(".")),
            _ => std::path::PathBuf::from("."),
        }
    };

    // Write a "cur" row directly into the sibling queue (mimicking a live drainer).
    let sibling_cfg = storage
        .configuration()
        .queue_sibling("queue.sqlite")
        .expect("queue_sibling");
    let qs: Arc<dyn Storage> = Arc::new(Sq::new(sibling_cfg).expect("open queue.sqlite"));
    PersistenceKitBackend::open_schema(qs.as_ref()).expect("open_schema");
    let pk = PersistenceKitBackend::new(Arc::clone(&qs));

    let j = Job {
        id: JobId("live-drainer-job-001".to_string()),
        stream_id: StreamId("encode".to_string()),
        submitted_at: HLC { physical_time: 1_000_000, logical_count: 0, node_id: 1 },
        priority: 50,
        payload: b"live-drainer-payload".to_vec(),
        extensions: Map::new(),
    };
    pk.write(&j).unwrap();
    let _claimed = pk.drain_available().unwrap();   // → cur

    // Write a FRESH lease: another "live" process holds the encode stream.
    write_fresh_encode_lease(&estate_dir, "pid-42-live-drainer");

    // Mount corpus2 — it should stand down because the fresh lease blocks acquire.
    let corpus2 = make_corpus(Arc::clone(&storage));
    corpus2.mount_ingest_queue().expect("mount queue 2");

    // Give the drain loop several passes.
    std::thread::sleep(std::time::Duration::from_millis(400));

    // The cur row must still be cur — corpus2 did not reclaim it.
    let in_flight = pk.in_flight().expect("in_flight");
    assert_eq!(
        in_flight.len(), 1,
        "live drainer's cur row must NOT be reclaimed when lease is fresh"
    );
    assert_eq!(in_flight[0].id, j.id);

    corpus2.drop_ingest_queue();
}

// ---------------------------------------------------------------------------
// 3. Corpus Drop idempotency (Part D)
// ---------------------------------------------------------------------------

/// drop_ingest_queue() must be safe to call twice. The Drop impl calls it
/// automatically; a manual call before drop must be harmless.
#[test]
fn drop_ingest_queue_idempotent() {
    let _guard = global_lock();

    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> =
        Arc::new(persistence_kit::inmemory::InMemoryStorage::new(config));
    let corpus = make_corpus(storage);

    corpus.mount_ingest_queue().expect("mount queue");

    // Manual drop — must succeed.
    corpus.drop_ingest_queue();

    // Second drop — must also succeed without panicking.
    corpus.drop_ingest_queue();

    // The Drop impl will call drop_ingest_queue a third time when corpus goes
    // out of scope — no panic = pass.
}
