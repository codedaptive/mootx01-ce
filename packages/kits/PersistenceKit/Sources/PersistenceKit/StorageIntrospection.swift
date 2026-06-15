// StorageIntrospection.swift
//
// DB-layer health statistics protocol and value type.
//
// moot-mgr uses this surface to read per-estate storage health for
// observed estates and for its own internal stats store. Exposed as
// a distinct protocol (not merged into Storage) so the addition is
// purely additive: existing Storage conformers are not broken, and
// consumers probe capability with `as? StorageIntrospection`.
//
// Design note: `StorageStats` carries an optional-or-zero discipline
// for backend-specific fields. A backend that cannot supply a field
// (e.g. InMemory has no WAL) sets it to nil. The per-field comments
// document which backend fills each field.

import Foundation

// MARK: - StorageStats

/// A point-in-time snapshot of backend storage health.
///
/// Field availability by backend:
///
/// | Field                  | SQLite | PostgreSQL | InMemory |
/// |------------------------|--------|------------|----------|
/// | logicalSizeBytes       |   ✓    |     ✓      |    ✓     |
/// | pageSize               |   ✓    |    nil     |   nil    |
/// | pageCount              |   ✓    |    nil     |   nil    |
/// | freelistPageCount      |   ✓    |    nil     |   nil    |
/// | walFrameCount          |   ✓    |    nil     |   nil    |
/// | cacheHitRatio          |   nil  |     ✓      |   nil    |
/// | transactionCommitCount |   nil  |     ✓      |   nil    |
/// | transactionRollbackCount|   nil  |     ✓      |    ✓     |
/// | deadlockCount          |   nil  |     ✓      |   nil    |
/// | lockContention         |   ✓    |     ✓      |   nil    |
/// | rowCount               |   nil  |    nil     |    ✓     |
/// | blobCount              |   nil  |    nil     |    ✓     |
/// | capturedAt             |   ✓    |     ✓      |    ✓     |
public struct StorageStats: Sendable, Equatable {

    // MARK: - Storage size fields

    /// Total logical size of the database in bytes.
    ///
    /// SQLite: page_count * page_size (PRAGMA page_count, page_size).
    /// PostgreSQL: pg_database_size(current_database()).
    /// InMemory: approximate bytes — sum of stored row values.
    public let logicalSizeBytes: Int64

    /// SQLite page size in bytes.
    ///
    /// SQLite: PRAGMA page_size.
    /// PostgreSQL: nil — page management is internal to the PG engine.
    /// InMemory: nil — no page model.
    public let pageSize: Int?

    /// Total number of pages allocated to the database (including freelist).
    ///
    /// SQLite: PRAGMA page_count. Multiply by pageSize for raw file size.
    /// PostgreSQL: nil.
    /// InMemory: nil.
    public let pageCount: Int?

    /// Number of unused (freelist) pages.
    ///
    /// SQLite: PRAGMA freelist_count. A high ratio of freelist/pageCount
    /// suggests the database should be VACUUMed to reclaim file space.
    /// PostgreSQL: nil.
    /// InMemory: nil.
    public let freelistPageCount: Int?

    // MARK: - WAL fields (SQLite only)

    /// Number of frames currently in the WAL file.
    ///
    /// SQLite WAL mode: read via `PRAGMA wal_checkpoint(PASSIVE)` — the
    /// call returns (busy, log, checkpointed); we report `log` (total WAL
    /// frames written since last full checkpoint). A large frame count
    /// means the WAL has grown and a checkpoint is overdue.
    ///
    /// Nil for backends where WAL is not applicable (PostgreSQL manages
    /// its WAL internally; InMemory has no persistence layer).
    public let walFrameCount: Int?

    // MARK: - Cache and transaction fields (PostgreSQL)

    /// Buffer-cache hit ratio: hits / (hits + reads).
    ///
    /// PostgreSQL: blks_hit / (blks_hit + blks_read) from
    /// pg_stat_database where datname = current_database(). A value
    /// close to 1.0 indicates most reads are served from shared_buffers.
    /// Returns nil when blks_hit + blks_read == 0 (no reads yet).
    ///
    /// SQLite: nil — SQLite's page cache is not exposed via a PRAGMA
    /// that returns lifetime counters, only configuration.
    /// InMemory: nil — all reads are in-process memory.
    public let cacheHitRatio: Double?

    /// Total committed transactions since backend was last reset.
    ///
    /// PostgreSQL: xact_commit from pg_stat_database.
    /// SQLite: nil — SQLite does not maintain a global commit counter
    /// accessible via PRAGMA (WAL checkpoint covers durability).
    /// InMemory: nil.
    public let transactionCommitCount: Int64?

    /// Total rolled-back transactions since backend was last reset.
    ///
    /// PostgreSQL: xact_rollback from pg_stat_database.
    /// InMemory: count of calls to the rollback path in InMemoryStorage.
    /// SQLite: nil.
    public let transactionRollbackCount: Int64?

    /// Total deadlocks detected since backend was last reset.
    ///
    /// PostgreSQL: deadlocks from pg_stat_database.
    /// SQLite: nil — SQLite serializes at the writer level; deadlocks
    /// are structurally impossible in WAL mode.
    /// InMemory: nil.
    public let deadlockCount: Int64?

    // MARK: - Lock contention

    /// Busy / lock-contention indicator.
    ///
    /// SQLite: true when the most recent PRAGMA busy_timeout fired
    /// (i.e. sqlite3_errmsg contains "database is locked"). Because
    /// the Swift backend serializes via an actor, contention means an
    /// external process is also accessing the file.
    ///
    /// PostgreSQL: true when pg_locks contains at least one waiting
    /// lock on any relation in the current database
    /// (wait = true in pg_locks join pg_database).
    ///
    /// InMemory: nil — in-process serialization; contention is not
    /// observable.
    public let lockContention: Bool?

    // MARK: - InMemory-specific counts

    /// Total row count across all tables.
    ///
    /// InMemory: sum of all table row counts.
    /// SQLite / PostgreSQL: nil — querying every user table is
    /// expensive and outside the scope of a health check.
    public let rowCount: Int?

    /// Total blob entry count.
    ///
    /// InMemory: count of entries in the blob store.
    /// SQLite / PostgreSQL: nil.
    public let blobCount: Int?

    // MARK: - Metadata

    /// Timestamp at which the snapshot was captured.
    ///
    /// Injected by the caller (determinism rule: no Date() inside engines).
    /// All backends: non-nil.
    public let capturedAt: Date

    // MARK: - Initializer

    public init(
        logicalSizeBytes: Int64,
        pageSize: Int? = nil,
        pageCount: Int? = nil,
        freelistPageCount: Int? = nil,
        walFrameCount: Int? = nil,
        cacheHitRatio: Double? = nil,
        transactionCommitCount: Int64? = nil,
        transactionRollbackCount: Int64? = nil,
        deadlockCount: Int64? = nil,
        lockContention: Bool? = nil,
        rowCount: Int? = nil,
        blobCount: Int? = nil,
        capturedAt: Date
    ) {
        self.logicalSizeBytes = logicalSizeBytes
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.freelistPageCount = freelistPageCount
        self.walFrameCount = walFrameCount
        self.cacheHitRatio = cacheHitRatio
        self.transactionCommitCount = transactionCommitCount
        self.transactionRollbackCount = transactionRollbackCount
        self.deadlockCount = deadlockCount
        self.lockContention = lockContention
        self.rowCount = rowCount
        self.blobCount = blobCount
        self.capturedAt = capturedAt
    }
}

// MARK: - StorageIntrospection protocol

/// Optional capability extension for `Storage` backends that can report
/// DB-layer health statistics.
///
/// Consumers probe capability with:
/// ```swift
/// if let introspectable = storage as? StorageIntrospection {
///     let stats = try await introspectable.stats(now: Date())
/// }
/// ```
///
/// All three PersistenceKit backends (SQLite, PostgreSQL, InMemory) conform.
/// External conformers and mock backends are not required to conform.
public protocol StorageIntrospection: Sendable {
    /// Capture a point-in-time snapshot of backend health statistics.
    ///
    /// - Parameter now: The timestamp to stamp on the snapshot. Pass
    ///   `Date()` at the call site; never call `Date()` inside the engine.
    /// - Returns: A `StorageStats` value. Fields the backend cannot supply
    ///   are `nil`.
    func stats(now: Date) async throws -> StorageStats
}
