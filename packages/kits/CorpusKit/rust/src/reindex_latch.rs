//! reindex_latch.rs — Rust twin of CorpusReindexLatch.swift.
//!
//! The "reindex owed" snap-fit latch. Called at the tail of every migration
//! that invalidates the dense float embedding lane. No boolean argument — the
//! function can only set the latch, never clear it. Clearing happens only
//! after a successful rebuild completes.
//!
//! ## Protocol (REINDEX_REQUIRED_MIGRATION_DESIGN §3.2)
//!
//!   0. Read the manifest flag. If already set, a rebuild is already owed —
//!      return immediately without touching the queue.
//!   1. Check the reindex stream: if a pending ('new') job already exists,
//!      go straight to the bit-set step.
//!   2. Enqueue a reindex marker job (best-effort; errors captured, not
//!      propagated).
//!   3. Read back once — a return-without-error is not proof of a durable row.
//!   4. Job confirmed: write the durable manifest flag.
//!   5. No job: leave the flag clear, print the deferral line.
//!
//! ## Rules (§3.2)
//!   * Dedupe via the manifest flag (step 0) — not via the stream count.
//!     `pending_count_for_stream` counts only `status = 'new'` rows; once
//!     the drainer claims the job ('new' → 'cur') or the job completes
//!     ('done'), it returns 0 and a naive stream-count guard would fire a
//!     second enqueue. The manifest flag is the durable "rebuild owed" record
//!     and is cleared only by a successful rebuild; checking it first closes
//!     both the claim-window and the completion-window.
//!   * Enqueue first, record after. Flag-without-job is the silent failure.
//!   * Verify by read-back, not by trusting the enqueue return value.
//!   * No retry loop. One attempt, one verification, then out.
//!   * Called at the tail of a sequential migration train. N steps produce
//!     exactly one rebuild. Concurrent callers are outside the documented
//!     contract; window (iii) is not addressed here.
//!   * Cleared only by a successful rebuild — never here.

use std::collections::BTreeMap;

// RowStore is NOT explicitly imported — `storage.row_store()` returns
// `Arc<dyn RowStore>` and query()/upsert() dispatch via vtable without the
// trait in scope (dynamic dispatch, not static method resolution).
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, TypedValue};
use queuekit::backend::QueueBackend;
use queuekit::facade::QueueKit;
use queuekit::job::{Job, JobId, StreamId};
use substrate_types::hlc::HLCGenerator;

/// The QueueKit stream for reindex marker jobs. Fixed string scoping all
/// reindex marker jobs to a single well-known stream. Dedupe is performed via
/// the manifest flag check in `reindex_required` — the stream key alone does
/// NOT prevent duplicate jobs because the queue backend deduplicates only by
/// job ID (primary key), not by stream.
///
/// Swift twin: `reindexStreamID` in `CorpusReindexLatch.swift`.
pub const REINDEX_STREAM_ID: &str = "reindex";

/// The raw key written into the estate's `manifest` table when a reindex is
/// owed. Written via `storage.row_store()` (the same PersistenceKit surface
/// `DrawerStore::set_meta` uses internally). Cleared only when a successful
/// rebuild completes — not by this function.
///
/// Swift twin: `reindexManifestKey` in `CorpusReindexLatch.swift`.
pub const REINDEX_MANIFEST_KEY: &str = "corpus_reindex_required";

/// Priority for the reindex marker job. Outranks routine encode work (50)
/// so recall quality is restored promptly after a migration, without
/// starving active ingest.
///
/// Per REINDEX_REQUIRED_MIGRATION_DESIGN §3.3: "Priority needs choosing:
/// a post-migration rebuild should outrank routine encode work, since recall
/// is degraded until it completes, without starving ingest of memories the
/// user is actively writing." Encode work runs at 50; reindex chosen at 80.
const REINDEX_JOB_PRIORITY: i32 = 80;

/// JSON payload for the reindex marker job. Opaque to QueueKit; the drain
/// worker that mission-2 wires will interpret it. A full reindex across all
/// four providers is requested — per-slot scope (§5.2) is mission-2 scope.
fn reindex_job_payload() -> Vec<u8> {
    br#"{"kind":"full_reindex"}"#.to_vec()
}

/// Mark that a corpus reindex is owed.
///
/// Checks the durable manifest flag first: if a rebuild is already owed,
/// returns `Ok(())` immediately without touching the queue. Otherwise
/// enqueues a marker job on the fixed `"reindex"` stream, reads back once to
/// confirm durability, and writes the estate-manifest flag only when the job
/// exists. No retry loop — one attempt, one verification, then out. N calls
/// from N migration steps produce exactly one queued rebuild.
///
/// Dedupe is performed via the manifest flag rather than the stream job count
/// because `pending_count_for_stream` counts only `status = 'new'` rows: once
/// the drainer claims the job ('new' → 'cur') or the job completes ('done'),
/// the count returns 0 and a stream-count guard would fire a second enqueue.
///
/// When the enqueue does not take, prints the deferral line to stdout and
/// returns `Ok(())`. The daily maintenance duty heals the miss within a day
/// (REINDEX_REQUIRED_MIGRATION_DESIGN §3.4).
///
/// # Parameters
///
/// * `queue`      — the estate's shared `queue.sqlite`-backed `QueueKit`.
/// * `storage`    — the estate storage; `row_store()` is used to read and
///                  write the manifest flag. The caller must ensure the
///                  manifest table exists and `storage` is open and writable.
/// * `now_millis` — the caller's wall-clock in milliseconds. Never call
///                  `SystemTime::now()` inside this function.
pub fn reindex_required<B: QueueBackend>(
    queue: &QueueKit<B>,
    storage: &dyn Storage,
    now_millis: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    let stream = StreamId(REINDEX_STREAM_ID.to_string());

    // Step 0: if the manifest flag is already set, a rebuild is already owed.
    // Return immediately without touching the queue. This is the primary dedupe
    // guard — it closes both the claim-window (job is 'cur', pending_count == 0)
    // and the completion-window (job is 'done', pending_count == 0) that a
    // stream-count-only guard cannot see.
    //
    // The flag is read by VALUE, not by row presence. Step 4 writes "1"; a
    // rebuild that clears the latch by updating the row's value to "0" rather
    // than deleting the row would otherwise leave a row that reads as "set"
    // forever, and this function would never enqueue another rebuild for the
    // life of the estate. Comparing against "1" makes both clearing styles —
    // delete-the-row and zero-the-value — behave identically. Integer 0/1 is
    // accepted alongside text because the manifest column is untyped in SQLite
    // and a writer may bind either representation. Swift twin: the `latchIsSet`
    // computation in `CorpusReindexLatch.swift`.
    let key_col = Column::new("manifest", "key");
    let existing_flag = storage
        .row_store()
        .query(
            "manifest",
            Some(&StoragePredicate::Eq(
                key_col,
                TypedValue::Text(REINDEX_MANIFEST_KEY.to_string()),
            )),
            &[],
            Some(1),
            None,
        )
        .map_err(|e| format!("manifest query failed: {e:?}"))?;
    let latch_is_set = match existing_flag.first().and_then(|row| row.get("value")) {
        Some(TypedValue::Text(s)) => s == "1",
        Some(TypedValue::Int(i)) => *i != 0,
        _ => false,
    };
    if latch_is_set {
        // Rebuild already owed — log to stderr (Rust has no OSLog) and return.
        eprintln!(
            "CorpusReindexLatch: latch already set — rebuild already owed, skipping enqueue"
        );
        return Ok(());
    }

    // Step 1: check whether the stream already carries a pending ('new') job
    // from a prior latch call on this upgrade run. If so, skip straight to the
    // bit-set step — the job acts as the durable backstop.
    let mut existing_count = queue.pending_count_for_stream(&stream)
        .unwrap_or(0);

    if existing_count == 0 {
        // Step 2: enqueue the reindex marker. Failure is absorbed — the
        // read-back (step 3) is the authoritative check.
        // HLC node 0: upgrade-time stamping is not estate-scoped; an
        // arbitrary low node avoids colliding with the estate's own HLC
        // streams and still produces a monotone timestamp.
        let mut hlc_gen = HLCGenerator::new(0);
        let stamp = hlc_gen.send(now_millis);

        // Generate a UUID-based job id, 32 lowercase hex chars, no hyphens
        // (mirrors Swift JobID.generate()).
        let id_raw = uuid::Uuid::new_v4()
            .simple()
            .to_string();
        let job = Job {
            id: JobId(id_raw),
            stream_id: stream.clone(),
            submitted_at: stamp,
            priority: REINDEX_JOB_PRIORITY,
            payload: reindex_job_payload(),
            extensions: serde_json::Map::new(),
        };

        // Best-effort: do not propagate an enqueue error. The read-back
        // captures any failure by returning 0 instead of 1.
        let _ = queue.send(&job);

        // Step 3: read back once. A returned-without-error is not proof of
        // a durable row; the pending count IS.
        existing_count = queue.pending_count_for_stream(&stream)
            .unwrap_or(0);
    }

    if existing_count > 0 {
        // Step 4: job confirmed — write the durable manifest flag.
        // Uses the same underlying PersistenceKit row_store().upsert that
        // DrawerStore::set_meta uses internally (manifest is a plain
        // key-value table in the estate SQLite).
        let mut values = BTreeMap::new();
        values.insert(
            "key".to_string(),
            TypedValue::Text(REINDEX_MANIFEST_KEY.to_string()),
        );
        values.insert("value".to_string(), TypedValue::Text("1".to_string()));
        storage
            .row_store()
            .upsert("manifest", values, &["key".to_string()])
            .map_err(|e| format!("manifest upsert failed: {e:?}"))?;
    } else {
        // Step 5: enqueue did not take. Leave the manifest flag clear so
        // the next `mootx01 upgrade` retries. Print the deferral line to
        // stdout — not stderr, no error marker, no underlying cause
        // (REINDEX_REQUIRED_MIGRATION_DESIGN §3.4 + Bob, 2026-08-14).
        println!(
            "  · reindex not scheduled — daily maintenance will rebuild the index.\n    Search results may be incomplete until it completes."
        );
    }

    Ok(())
}
