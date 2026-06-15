//! Self-report telemetry layer for PersistenceKit's `StorageIntrospection` surface.
//!
//! This module owns `report_storage_stats`, which calls
//! `StorageIntrospection::stats(now_secs)` and emits the resulting fields
//! as `StatSample::metric` samples via the `report!` macro.
//!
//! ## Design decisions
//!
//! 1. **OFF by default, zero cost when disabled.**
//!    The `report!` macro body is only evaluated when
//!    `Intellectus::is_enabled()` is true. When disabled, each call is a
//!    single `AtomicBool::load(Acquire)` + branch (~1 ns, lock-free). The
//!    `StorageIntrospection::stats(now_secs)` call itself is the only
//!    meaningful work, and it is only made if the caller wants stats.
//!
//! 2. **Caller-supplied timestamp.**
//!    `now_secs` is always injected by the caller (determinism rule: never
//!    call a clock inside an engine). The `ts` field of each emitted metric
//!    is `now_secs as f64`.
//!
//! 3. **Estate tag on every metric.**
//!    Every emitted metric carries `estate: <estate_id>` so per-estate
//!    DB health is queryable at the observer end.
//!
//! 4. **None fields are skipped.**
//!    `StorageStats` fields that are `None` for a given backend are not
//!    emitted. WAL fields are `None` for InMemory and PostgreSQL.
//!
//! 5. **Metric namespace: `persistence.db.*`**
//!    Sub-namespaces:
//!    - `persistence.db.size_bytes`      — logical size (all backends)
//!    - `persistence.db.page_size`       — SQLite page size (SQLite only)
//!    - `persistence.db.page_count`      — total pages (SQLite only)
//!    - `persistence.db.freelist_pages`  — freelist pages (SQLite only)
//!    - `persistence.db.wal_frames`      — WAL frame count (SQLite only)
//!    - `persistence.db.cache_hit_ratio` — cache hit ratio (PostgreSQL only)
//!    - `persistence.db.tx_commits`      — committed transactions (PostgreSQL)
//!    - `persistence.db.tx_rollbacks`    — rolled-back transactions (PG + InMemory)
//!    - `persistence.db.deadlocks`       — deadlock count (PostgreSQL only)
//!    - `persistence.db.lock_contention` — lock contention flag (SQLite + PG)
//!    - `persistence.db.row_count`       — total row count (InMemory only)
//!    - `persistence.db.blob_count`      — blob count (InMemory only)
//!
//! 6. **Conformance guarantee.**
//!    `report_storage_stats` does not modify the stats returned by
//!    `stats(now_secs)`, does not alter backend state, and does not affect
//!    any returned value. StorageStats is unchanged by telemetry.
//!
//! Mirror of Swift `PersistenceKitTelemetry.swift`.

use crate::introspection::StorageIntrospection;
use intellectus_lib::{Intellectus, StatSample, report};
use std::collections::HashMap;

/// Capture a `StorageStats` snapshot from `storage` and emit all non-`None`
/// fields as `StatSample::metric` samples via the `report!` macro.
///
/// When `Intellectus::is_enabled()` is `false` (the default), this function
/// returns immediately after a single `AtomicBool` load + branch without
/// calling `stats(now_secs)` or constructing any samples.
///
/// When monitoring is enabled, `stats(now_secs)` is called exactly once and
/// each non-`None` field is emitted as a separate metric in the
/// `persistence.db.*` namespace.
///
/// # Parameters
///
/// - `storage`: Any type implementing `StorageIntrospection`.
/// - `estate_id`: The estate identifier, carried as the `estate` tag on every
///   emitted metric so per-estate health is queryable.
/// - `now_secs`: Caller-supplied Unix timestamp (seconds). Stamped on the
///   `StorageStats.captured_at_secs` field and used as `ts` in each metric.
///   Never call `SystemTime::now()` inside this function — the caller must
///   supply the time (determinism rule).
pub fn report_storage_stats(
    storage: &dyn StorageIntrospection,
    estate_id: &str,
    now_secs: i64,
) {
    // OFF-path gate: single atomic load. If monitoring is disabled, return
    // immediately — do not call stats(now_secs), do not build any samples.
    // This mirrors the Swift guard Intellectus.isEnabled else { return } pattern.
    if !Intellectus::is_enabled() {
        return;
    }

    // Fetch the stats snapshot — on-path only.
    let stats = match storage.stats(now_secs) {
        Ok(s) => s,
        Err(_) => {
            // Telemetry failure must never degrade the caller's path. Log nothing
            // here (no logger dependency); silently return.
            return;
        }
    };

    let ts = now_secs as f64;

    // Build the base tag map shared by every emitted metric.
    // kit: identifies the emitting kit for fan-out filtering.
    // estate: per-estate queryability.
    let make_tags = || -> HashMap<String, String> {
        let mut tags = HashMap::new();
        tags.insert("kit".to_string(), "PersistenceKit".to_string());
        tags.insert("estate".to_string(), estate_id.to_string());
        tags
    };

    // Emit logical DB size. All backends supply this field.
    report!({
        StatSample::metric(
            "persistence.db.size_bytes".to_string(),
            stats.logical_size_bytes as f64,
            make_tags(),
            ts,
        )
    });

    // SQLite-only fields: page_size, page_count, freelist_pages.
    // These are None for InMemory and PostgreSQL — skip them for those backends.

    if let Some(page_size) = stats.page_size {
        // SQLite page size in bytes. Constant for the lifetime of a file.
        // Standard values: 512, 1024, 2048, 4096 (default), 8192, 16384, 32768, 65536.
        report!({
            StatSample::metric(
                "persistence.db.page_size".to_string(),
                page_size as f64,
                make_tags(),
                ts,
            )
        });
    }

    if let Some(page_count) = stats.page_count {
        // Total pages allocated (including freelist). Multiply by page_size
        // for the physical file size. High page count with high freelist ratio
        // suggests a VACUUM would reclaim space.
        report!({
            StatSample::metric(
                "persistence.db.page_count".to_string(),
                page_count as f64,
                make_tags(),
                ts,
            )
        });
    }

    if let Some(freelist_count) = stats.freelist_page_count {
        // Free (unused) pages. freelist_pages / page_count indicates fragmentation.
        report!({
            StatSample::metric(
                "persistence.db.freelist_pages".to_string(),
                freelist_count as f64,
                make_tags(),
                ts,
            )
        });
    }

    // WAL field: SQLite only (WAL mode).
    // wal_frame_count is the number of frames in the WAL file since the last
    // full checkpoint. Derived from the WAL file size (see introspection.rs).
    if let Some(wal_frames) = stats.wal_frame_count {
        report!({
            StatSample::metric(
                "persistence.db.wal_frames".to_string(),
                wal_frames as f64,
                make_tags(),
                ts,
            )
        });
    }

    // PostgreSQL-only fields.

    if let Some(hit_ratio) = stats.cache_hit_ratio {
        // Buffer-cache hit ratio: blks_hit / (blks_hit + blks_read).
        // Near 1.0 = most reads served from shared_buffers (good).
        report!({
            StatSample::metric(
                "persistence.db.cache_hit_ratio".to_string(),
                hit_ratio,
                make_tags(),
                ts,
            )
        });
    }

    if let Some(commits) = stats.transaction_commit_count {
        // Total committed transactions since last statistics reset.
        report!({
            StatSample::metric(
                "persistence.db.tx_commits".to_string(),
                commits as f64,
                make_tags(),
                ts,
            )
        });
    }

    // tx_rollbacks is available for PostgreSQL and InMemory.
    if let Some(rollbacks) = stats.transaction_rollback_count {
        // Rollback count: PostgreSQL = xact_rollback; InMemory = rollback path count.
        report!({
            StatSample::metric(
                "persistence.db.tx_rollbacks".to_string(),
                rollbacks as f64,
                make_tags(),
                ts,
            )
        });
    }

    if let Some(deadlocks) = stats.deadlock_count {
        // PostgreSQL only. Non-zero is a signal to investigate locking order.
        report!({
            StatSample::metric(
                "persistence.db.deadlocks".to_string(),
                deadlocks as f64,
                make_tags(),
                ts,
            )
        });
    }

    // Lock contention: SQLite + PostgreSQL. None for InMemory.
    if let Some(contention) = stats.lock_contention {
        // Encode bool as 1.0 / 0.0 so it is plottable as a metric value.
        // SQLite: true when SQLITE_LOCKED returned by a read-only PRAGMA probe.
        // PostgreSQL: true when pg_locks has a waiting lock on this database.
        report!({
            StatSample::metric(
                "persistence.db.lock_contention".to_string(),
                if contention { 1.0 } else { 0.0 },
                make_tags(),
                ts,
            )
        });
    }

    // InMemory-specific fields: row_count, blob_count.
    // These are None for SQLite and PostgreSQL.

    if let Some(row_count) = stats.row_count {
        // Sum of all row counts across all tables in the InMemory backend.
        report!({
            StatSample::metric(
                "persistence.db.row_count".to_string(),
                row_count as f64,
                make_tags(),
                ts,
            )
        });
    }

    if let Some(blob_count) = stats.blob_count {
        // Number of entries in the InMemory blob store.
        report!({
            StatSample::metric(
                "persistence.db.blob_count".to_string(),
                blob_count as f64,
                make_tags(),
                ts,
            )
        });
    }
}
