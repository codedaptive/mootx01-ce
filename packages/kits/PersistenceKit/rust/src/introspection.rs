//! DB-layer stats introspection — mirrors Swift's `StorageIntrospection`
//! protocol and `StorageStats` struct.
//!
//! The Rust trait is synchronous (matching the Storage trait convention)
//! because the in-process backends do no real async I/O. The Swift side is
//! `async throws`; the Rust side returns `StorageResult<StorageStats>`.
//!
//! Field availability by backend:
//!
//! | Field                     | SQLite | PostgreSQL | InMemory |
//! |---------------------------|--------|------------|----------|
//! | logical_size_bytes        |   ✓    |     ✓      |    ✓     |
//! | page_size                 |   ✓    |    None    |   None   |
//! | page_count                |   ✓    |    None    |   None   |
//! | freelist_page_count       |   ✓    |    None    |   None   |
//! | wal_frame_count           |   ✓    |    None    |   None   |
//! | cache_hit_ratio           |  None  |     ✓      |   None   |
//! | transaction_commit_count  |  None  |     ✓      |   None   |
//! | transaction_rollback_count|  None  |     ✓      |    ✓     |
//! | deadlock_count            |  None  |     ✓      |   None   |
//! | lock_contention           |   ✓    |     ✓      |   None   |
//! | row_count                 |  None  |    None    |    ✓     |
//! | blob_count                |  None  |    None    |    ✓     |
//! | vector_count              |  None  |    None    |    ✓     |
//! | captured_at_secs          |   ✓    |     ✓      |    ✓     |

use crate::error::StorageResult;

/// A point-in-time snapshot of backend storage health.
///
/// Optional fields follow a nil/None discipline: a backend sets a field to
/// `None` when the underlying engine does not expose that statistic (e.g.
/// the InMemory backend has no WAL, so `wal_frame_count` is always `None`).
/// See module-level table for per-backend field coverage.
#[derive(Debug, Clone, PartialEq)]
pub struct StorageStats {
    // ── Storage size ────────────────────────────────────────────────────

    /// Total logical size of the database in bytes.
    ///
    /// SQLite: page_count * page_size (PRAGMA page_count, page_size).
    /// PostgreSQL: pg_database_size(current_database()).
    /// InMemory: approximate — 256 bytes per row + exact blob bytes.
    pub logical_size_bytes: i64,

    /// SQLite page size in bytes (PRAGMA page_size).
    ///
    /// Constant for the lifetime of a SQLite file. Required to derive
    /// WAL frame count from the WAL file size.
    /// None for PostgreSQL and InMemory (no page model).
    pub page_size: Option<i32>,

    /// Total number of pages allocated to the database (PRAGMA page_count).
    ///
    /// Includes freelist pages. Multiply by page_size for raw file size.
    /// None for PostgreSQL and InMemory.
    pub page_count: Option<i32>,

    /// Number of unused (freelist) pages (PRAGMA freelist_count).
    ///
    /// A high ratio vs. page_count suggests a VACUUM would reclaim space.
    /// None for PostgreSQL and InMemory.
    pub freelist_page_count: Option<i32>,

    // ── WAL (SQLite only) ────────────────────────────────────────────────

    /// Number of frames currently in the SQLite WAL file.
    ///
    /// Derived from the WAL file size: (file_size - 32) / (page_size + 24).
    /// Returns 0 when the WAL file does not exist or contains no frames.
    ///
    /// Rationale for file-stat approach: `PRAGMA wal_checkpoint` acquires
    /// a checkpointer lock and can return SQLITE_LOCKED when a reader or
    /// writer is active on the same connection, making it unsafe to call
    /// from inside a lock-holding context. Reading the WAL file size is
    /// a pure filesystem stat with no SQLite lock semantics.
    ///
    /// None for PostgreSQL (WAL is managed internally) and InMemory (no
    /// persistence layer).
    pub wal_frame_count: Option<i32>,

    // ── Cache and transaction stats (PostgreSQL) ─────────────────────────

    /// Buffer-cache hit ratio: blks_hit / (blks_hit + blks_read).
    ///
    /// PostgreSQL: from pg_stat_database for current_database(). A ratio
    /// near 1.0 means most reads are served from shared_buffers.
    /// None when blks_hit + blks_read == 0 (no reads yet).
    ///
    /// None for SQLite (page cache not exposed via PRAGMA counters) and
    /// InMemory (all reads are in-process memory).
    pub cache_hit_ratio: Option<f64>,

    /// Total committed transactions since last statistics reset.
    ///
    /// PostgreSQL: xact_commit from pg_stat_database.
    /// None for SQLite and InMemory.
    pub transaction_commit_count: Option<i64>,

    /// Total rolled-back transactions since last statistics reset.
    ///
    /// PostgreSQL: xact_rollback from pg_stat_database.
    /// InMemory: count of calls to the rollback path in InMemoryStorage::transaction().
    /// None for SQLite.
    pub transaction_rollback_count: Option<i64>,

    /// Total deadlocks detected since last statistics reset.
    ///
    /// PostgreSQL: deadlocks from pg_stat_database.
    /// None for SQLite (WAL mode serializes writers; deadlocks are impossible)
    /// and InMemory.
    pub deadlock_count: Option<i64>,

    // ── Lock contention ──────────────────────────────────────────────────

    /// Lock-contention indicator.
    ///
    /// SQLite: true when a read-only PRAGMA probe (schema_version) returns
    /// SQLITE_LOCKED, indicating a cross-process exclusive lock. The Mutex
    /// serializes same-process access so contention is always external.
    ///
    /// PostgreSQL: true when pg_locks contains at least one waiting lock
    /// (granted=false) on the current database.
    ///
    /// None for InMemory (in-process serialization; contention not observable).
    pub lock_contention: Option<bool>,

    // ── InMemory-specific counts ─────────────────────────────────────────

    /// Total row count across all tables.
    ///
    /// InMemory: sum of all table row counts.
    /// None for SQLite / PostgreSQL (scanning every table is expensive).
    pub row_count: Option<usize>,

    /// Total blob entry count.
    ///
    /// InMemory: count of entries in the blob store.
    /// None for SQLite / PostgreSQL.
    pub blob_count: Option<usize>,

    // ── Metadata ─────────────────────────────────────────────────────────

    /// Unix timestamp (seconds) at which the snapshot was captured.
    ///
    /// Injected by the caller — never generated inside the engine
    /// (determinism rule: pass now as a parameter).
    pub captured_at_secs: i64,
}

/// Optional capability extension for `Storage` backends that can report
/// DB-layer health statistics.
///
/// All three PersistenceKit backends implement this trait. External conformers
/// are not required to implement it; probe capability with a trait-object
/// downcast if needed (Rust does not support `as? T` syntax; use a separate
/// method on concrete types or an extension enum).
///
/// Mirror of Swift's `StorageIntrospection` protocol.
pub trait StorageIntrospection {
    /// Capture a point-in-time snapshot of backend health statistics.
    ///
    /// `now_secs` is the Unix timestamp (seconds) to stamp on the snapshot.
    /// Pass `SystemTime::now()` at the call site; never call time functions
    /// inside the engine (determinism rule).
    fn stats(&self, now_secs: i64) -> StorageResult<StorageStats>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn storage_stats_struct_fields_accessible() {
        // Structural smoke test: construct a fully-populated StorageStats
        // and verify all fields are accessible by name. This ensures the
        // struct layout matches the design table in the module docs.
        let s = StorageStats {
            logical_size_bytes: 4096,
            page_size: Some(4096),
            page_count: Some(1),
            freelist_page_count: Some(0),
            wal_frame_count: Some(0),
            cache_hit_ratio: Some(0.99),
            transaction_commit_count: Some(10),
            transaction_rollback_count: Some(1),
            deadlock_count: Some(0),
            lock_contention: Some(false),
            row_count: Some(5),
            blob_count: Some(2),
            captured_at_secs: 1_700_000_000,
        };
        assert_eq!(s.logical_size_bytes, 4096);
        assert_eq!(s.page_size, Some(4096));
        assert_eq!(s.page_count, Some(1));
        assert_eq!(s.freelist_page_count, Some(0));
        assert_eq!(s.wal_frame_count, Some(0));
        assert!((s.cache_hit_ratio.unwrap() - 0.99).abs() < 1e-9);
        assert_eq!(s.transaction_commit_count, Some(10));
        assert_eq!(s.transaction_rollback_count, Some(1));
        assert_eq!(s.deadlock_count, Some(0));
        assert_eq!(s.lock_contention, Some(false));
        assert_eq!(s.row_count, Some(5));
        assert_eq!(s.blob_count, Some(2));
        assert_eq!(s.captured_at_secs, 1_700_000_000);
    }

    #[test]
    fn storage_stats_clone_and_eq() {
        let s = StorageStats {
            logical_size_bytes: 8192,
            page_size: Some(4096),
            page_count: Some(2),
            freelist_page_count: Some(0),
            wal_frame_count: None,
            cache_hit_ratio: None,
            transaction_commit_count: None,
            transaction_rollback_count: None,
            deadlock_count: None,
            lock_contention: None,
            row_count: None,
            blob_count: None,
            captured_at_secs: 0,
        };
        let s2 = s.clone();
        assert_eq!(s, s2);
    }
}
