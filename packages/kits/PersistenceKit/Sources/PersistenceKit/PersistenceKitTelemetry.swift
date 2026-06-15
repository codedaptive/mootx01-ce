// PersistenceKitTelemetry.swift
//
// Self-report telemetry layer for PersistenceKit's StorageIntrospection surface.
//
// This file owns the `reportStorageStats(_:estateID:now:)` function, which
// calls `StorageIntrospection.stats(now:)` and emits the resulting fields
// as `StatSample.metric` samples via `Intellectus.report(_:)`.
//
// Design decisions:
//
// 1. OFF by default, zero cost when disabled.
//    The `Intellectus.report(_:)` autoclosure is only evaluated when
//    `Intellectus.isEnabled` is true. When disabled, each call is a single
//    `Atomic<Bool>.load(.acquiring)` + branch (~1 ns, lock-free). The
//    `StorageIntrospection.stats(now:)` call itself is the only meaningful
//    work on the hot path, and it is only made if the caller wants stats.
//
// 2. Caller-supplied timestamp.
//    `now` is always injected by the caller (determinism rule: never call
//    `Date()` inside an engine). The `ts` field of each `StatSample.metric`
//    is `now.timeIntervalSince1970`.
//
// 3. Estate tag on every metric.
//    Every emitted metric carries `estate: <estateID-string>` so per-estate
//    DB health is queryable at the observer end.
//
// 4. Nil fields are skipped.
//    `StorageStats` fields that are `nil` for a given backend are not emitted.
//    For example, WAL fields are nil for InMemory and PostgreSQL — those
//    metrics do not appear in their stat streams. This keeps the metric
//    namespace clean and avoids misleading zero values.
//
// 5. Metric namespace: `persistence.db.*`
//    All metrics emitted by this file carry the `persistence.db.` prefix.
//    Sub-namespaces:
//      persistence.db.size_bytes         — logical size
//      persistence.db.page_size          — SQLite page size (SQLite only)
//      persistence.db.page_count         — total pages (SQLite only)
//      persistence.db.freelist_pages     — freelist pages (SQLite only)
//      persistence.db.wal_frames         — WAL frame count (SQLite only)
//      persistence.db.cache_hit_ratio    — cache hit ratio (PostgreSQL only)
//      persistence.db.tx_commits         — committed transactions (PostgreSQL)
//      persistence.db.tx_rollbacks       — rolled-back transactions (PG + InMemory)
//      persistence.db.deadlocks          — deadlock count (PostgreSQL only)
//      persistence.db.lock_contention    — lock contention flag (SQLite + PG)
//      persistence.db.row_count          — total row count (InMemory only)
//      persistence.db.blob_count         — blob count (InMemory only)
//
// 6. Conformance guarantee.
//    `reportStorageStats` does not modify the stats returned by `stats(now:)`,
//    does not alter backend state, and does not affect the return value. The
//    emitted metrics are side effects only. StorageStats is unchanged by telemetry.

import Foundation
import IntellectusLib
import OSLog

private let logger = Logger(subsystem: "com.mootx01.kit", category: "PersistenceKit")

// MARK: - Public entry point

/// Capture a `StorageStats` snapshot from `storage` and emit all non-nil
/// fields as `StatSample.metric` samples via `Intellectus.report(_:)`.
///
/// When `Intellectus.isEnabled` is `false` (the default), this function
/// returns immediately after a single `Atomic<Bool>` load + branch without
/// calling `stats(now:)` or constructing any samples. No allocation, no I/O.
///
/// When monitoring is enabled, `stats(now:)` is called exactly once and each
/// non-nil field is emitted as a separate metric in the `persistence.db.*`
/// namespace. Fields that are `nil` for the current backend are not emitted.
///
/// - Parameters:
///   - storage: Any storage backend conforming to `StorageIntrospection`.
///   - estateID: The estate identifier, carried as the `estate` tag on every
///     emitted metric so per-estate health is queryable.
///   - now: Caller-supplied timestamp. Stamped on the `StorageStats.capturedAt`
///     field and used as `ts` in each emitted metric.
///     Never pass `Date()` inline here — capture the timestamp at your call site
///     and pass it through (determinism rule).
public func reportStorageStats(
    _ storage: any StorageIntrospection,
    estateID: String,
    now: Date
) async {
    // OFF-path gate: single atomic load. If monitoring is disabled, return
    // immediately — do not call stats(now:), do not build any samples.
    // This is the zero-cost disabled path specified in the mission.
    guard Intellectus.isEnabled else { return }

    // Fetch the stats snapshot. On the ON-path only.
    let stats: StorageStats
    do {
        stats = try await storage.stats(now: now)
    } catch {
        // If the backend cannot produce stats, log and bail. Do not propagate
        // the error — telemetry failure must never degrade the caller's path.
        logger.warning("PersistenceKitTelemetry: stats() failed for estate \(estateID): \(error)")
        return
    }

    let ts = now.timeIntervalSince1970

    // Common tags carried by every emitted metric.
    // kit: identifies the emitting kit for fan-out filtering.
    // estate: per-estate queryability.
    let baseTags: [String: String] = [
        "kit": "PersistenceKit",
        "estate": estateID,
    ]

    // Emit logical DB size. All backends supply this field.
    Intellectus.report(.metric(
        name: "persistence.db.size_bytes",
        value: Double(stats.logicalSizeBytes),
        tags: baseTags,
        ts: ts
    ))

    // SQLite-only fields: page_size, page_count, freelist_pages.
    // These are nil for InMemory and PostgreSQL — skip them for those backends.

    if let pageSize = stats.pageSize {
        // SQLite page size in bytes. Constant for the lifetime of a file.
        // Standard values: 512, 1024, 2048, 4096 (default), 8192, 16384, 32768, 65536.
        Intellectus.report(.metric(
            name: "persistence.db.page_size",
            value: Double(pageSize),
            tags: baseTags,
            ts: ts
        ))
    }

    if let pageCount = stats.pageCount {
        // Total pages allocated (including freelist). Multiply by pageSize
        // for the physical file size. High page count with high freelist ratio
        // suggests a VACUUM would reclaim space.
        Intellectus.report(.metric(
            name: "persistence.db.page_count",
            value: Double(pageCount),
            tags: baseTags,
            ts: ts
        ))
    }

    if let freelistCount = stats.freelistPageCount {
        // Free (unused) pages. freelist_pages / page_count indicates fragmentation.
        // A ratio above ~0.25 is a signal to consider running VACUUM.
        Intellectus.report(.metric(
            name: "persistence.db.freelist_pages",
            value: Double(freelistCount),
            tags: baseTags,
            ts: ts
        ))
    }

    // WAL field: SQLite only (WAL mode).
    // walFrameCount is the number of frames in the WAL file since the last
    // full checkpoint. A large count means the WAL has grown and a
    // PRAGMA wal_checkpoint(TRUNCATE) would be beneficial.
    if let walFrames = stats.walFrameCount {
        Intellectus.report(.metric(
            name: "persistence.db.wal_frames",
            value: Double(walFrames),
            tags: baseTags,
            ts: ts
        ))
    }

    // PostgreSQL-only fields.

    if let hitRatio = stats.cacheHitRatio {
        // Buffer-cache hit ratio: blks_hit / (blks_hit + blks_read).
        // Near 1.0 = most reads served from shared_buffers (good).
        // Near 0.0 = most reads hit disk (pressure on shared_buffers).
        Intellectus.report(.metric(
            name: "persistence.db.cache_hit_ratio",
            value: hitRatio,
            tags: baseTags,
            ts: ts
        ))
    }

    if let commits = stats.transactionCommitCount {
        // Total committed transactions since last statistics reset (xact_commit).
        Intellectus.report(.metric(
            name: "persistence.db.tx_commits",
            value: Double(commits),
            tags: baseTags,
            ts: ts
        ))
    }

    // tx_rollbacks is available for PostgreSQL and InMemory.
    if let rollbacks = stats.transactionRollbackCount {
        // Rollback count: PostgreSQL = xact_rollback; InMemory = rollback path count.
        Intellectus.report(.metric(
            name: "persistence.db.tx_rollbacks",
            value: Double(rollbacks),
            tags: baseTags,
            ts: ts
        ))
    }

    if let deadlocks = stats.deadlockCount {
        // PostgreSQL only. Non-zero count is a signal to investigate contention
        // in the application's transaction locking order.
        Intellectus.report(.metric(
            name: "persistence.db.deadlocks",
            value: Double(deadlocks),
            tags: baseTags,
            ts: ts
        ))
    }

    // Lock contention: SQLite + PostgreSQL. Nil for InMemory.
    // SQLite: true if an external process holds an exclusive lock.
    // PostgreSQL: true if pg_locks has a waiting lock on this database.
    if let contention = stats.lockContention {
        Intellectus.report(.metric(
            name: "persistence.db.lock_contention",
            value: contention ? 1.0 : 0.0,
            tags: baseTags,
            ts: ts
        ))
    }

    // InMemory-specific fields: row_count, blob_count.
    // These are nil for SQLite and PostgreSQL.

    if let rowCount = stats.rowCount {
        // Sum of all row counts across all tables in the InMemory backend.
        Intellectus.report(.metric(
            name: "persistence.db.row_count",
            value: Double(rowCount),
            tags: baseTags,
            ts: ts
        ))
    }

    if let blobCount = stats.blobCount {
        // Number of entries in the InMemory blob store.
        Intellectus.report(.metric(
            name: "persistence.db.blob_count",
            value: Double(blobCount),
            tags: baseTags,
            ts: ts
        ))
    }

}
