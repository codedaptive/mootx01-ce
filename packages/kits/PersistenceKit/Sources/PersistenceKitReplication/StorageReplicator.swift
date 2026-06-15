// StorageReplicator.swift
//
// Generic full-snapshot replication primitive (§5 of the PersistenceKit
// Estate Replication spec). Implements replicate(from:to:schema:)
// and exposes flush / hydrate conveniences.
//
// CONTRACT:
//   - Schema gate: source and destination must have the same per-kit
//     schemaVersion. No auto-migration.
//   - Atomicity: the entire destination write is wrapped in a serializable
//     transaction. A crash or error mid-flush leaves the destination at its
//     prior consistent state. Blob writes happen INSIDE the same transaction
//     so a crash mid-flush does not leave a partial blob set.
//   - Row snapshot: all rows in schema.tables, including tombstoned rows and
//     rows in append-only tables, are copied verbatim. Generated columns are
//     FILTERED OUT before upsert — the destination backend recomputes them.
//   - Idempotent upsert: conflict key is table.primaryKey, NOT RowHandle.key
//     (which is a random UUID and changes between runs).
//   - Audit copy: _storagekit_audit is NOT in schema.tables; it is copied
//     via a separate auditLog.iterate → appendBatch path. This is load-bearing
//     for downstream matrix rebuild (which consumes the audit log).
//   - Blob copy: _storagekit_blobs is NOT in schema.tables. The BlobStore
//     protocol exposes listKeys() to enumerate all stored keys. The snapshot
//     reads every key from source and writes it to destination inside the same
//     serializable transaction as the row and audit copies. A corrupt or
//     unreadable blob (get returns nil) aborts the entire flush with
//     ReplicationError.storageFailure — fail-loud discipline; no silent skipping.
//   - TypedValue is copied verbatim (no coercion). ISO-8601 TEXT timestamps
//     round-trip through the backend without alteration (schema invariant I-3).
//   - HLC watermark: the max HLC seen across all copied rows' hlc-typed columns
//     and all copied audit events is returned in the ReplicationCursor.

import Foundation
import PersistenceKit
import SubstrateTypes
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "PersistenceKitReplication")

// MARK: - ReplicationPayload (internal transfer type)

/// Intermediate value holding the source snapshot captured before the
/// destination transaction opens. Sendable because all constituent types
/// are Sendable (TypedValue, AuditEvent, String, Data are all Sendable).
private struct ReplicationPayload: Sendable {
    /// Per-table row snapshots. Generated columns have been filtered
    /// out from each row's values dict; the destination recomputes them.
    let tableSnapshots: [(tableName: String, primaryKey: [String], rows: [[String: TypedValue]])]
    /// All audit events from the source's _storagekit_audit table.
    let auditEvents: [AuditEvent]
    /// All blob (key, bytes) pairs from the source's _storagekit_blobs store.
    ///
    /// Captured before the destination transaction opens so the transaction
    /// duration is not inflated by blob I/O from the source. Keys are sorted
    /// for deterministic write order across repeated flush calls.
    let blobs: [(key: BlobKey, bytes: Data)]
}

// MARK: - StorageReplicator

/// Namespace for the generic storage replication primitive.
///
/// `StorageReplicator.replicate(from:to:schema:)` is the core engine — it always
/// performs a full snapshot: all rows, all audit events, all blobs, atomically.
/// `flush(from:into:schema:)` and `hydrate(into:from:schema:)` are thin
/// convenience wrappers that name the direction explicitly.
///
/// For session-oriented incremental replication (observer-driven dirty-set),
/// use `IncrementalReplicationSession` directly.
public enum StorageReplicator {

    // MARK: - Core primitive

    /// Copy the full projected state of `source` into `destination`.
    ///
    /// Always performs a full snapshot: every row in every schema-declared table,
    /// all audit events, and all blobs are copied atomically in a serializable
    /// transaction. The operation is idempotent — a second call with no source
    /// changes writes zero new rows (upsert on primary key is a no-op for
    /// identical values).
    ///
    /// - Parameters:
    ///   - source: The storage to read from (must be open).
    ///   - destination: The storage to write to (must be open).
    ///   - schema: The schema declaration governing which tables to copy.
    ///     Must be the same schema applied to both backends.
    /// - Returns: A `ReplicationCursor` carrying the HLC watermark and counts.
    /// - Throws: `ReplicationError` if the schema gate fails or a storage
    ///   operation fails.
    public static func replicate(
        from source: any Storage,
        to destination: any Storage,
        schema: SchemaDeclaration
    ) async throws -> ReplicationCursor {
        return try await replicateFull(from: source, to: destination, schema: schema)
    }

    // MARK: - Conveniences

    /// Flush an in-memory storage into a durable storage.
    ///
    /// Equivalent to `replicate(from: inMemory, to: durable, schema: schema)`.
    /// The entire write to `durable` is atomic; a failure leaves `durable` unchanged.
    public static func flush(
        from inMemory: any Storage,
        into durable: any Storage,
        schema: SchemaDeclaration
    ) async throws -> ReplicationCursor {
        try await replicate(from: inMemory, to: durable, schema: schema)
    }

    /// Hydrate a fresh in-memory storage from a durable storage.
    ///
    /// Equivalent to `replicate(from: durable, to: inMemory, schema: schema)`.
    /// Call this on a freshly-opened InMemoryStorage instance.
    public static func hydrate(
        into inMemory: any Storage,
        from durable: any Storage,
        schema: SchemaDeclaration
    ) async throws -> ReplicationCursor {
        try await replicate(from: durable, to: inMemory, schema: schema)
    }

    // MARK: - Full-snapshot implementation

    private static func replicateFull(
        from source: any Storage,
        to destination: any Storage,
        schema: SchemaDeclaration
    ) async throws -> ReplicationCursor {

        // ── Step 1: Schema gate ───────────────────────────────────────
        // Both backends must be at the same per-kit schema version.
        // We check per-kit versions (not the global maximum) so that a
        // multi-kit estate gated on LocusKit version does not accidentally
        // clear when another kit's migrations advanced the global counter.
        let srcVersion = try await source.currentSchemaVersion(for: schema.kitID)
        let dstVersion = try await destination.currentSchemaVersion(for: schema.kitID)

        guard srcVersion == dstVersion && srcVersion == schema.version else {
            throw ReplicationError.schemaMismatch(
                sourceVersion: srcVersion,
                destinationVersion: dstVersion,
                sourceKitID: schema.kitID,
                destinationKitID: schema.kitID
            )
        }

        // ── Step 2: Snapshot source data (before opening the destination txn) ──
        // All source reads happen before the destination transaction opens so we
        // are not holding a long-lived serializable transaction during potentially
        // slow source I/O (especially relevant for remote/SQLite sources).
        let payload = try await snapshotSource(source: source, schema: schema)

        // ── Step 3: Write destination inside a serializable transaction ──
        // A serializable transaction ensures atomicity: a crash or error
        // mid-flush leaves the destination at its prior consistent state.
        //
        // Swift 6 strict concurrency: the @Sendable transaction closure cannot
        // mutate non-Sendable captured vars. We collect results via a Sendable
        // holder type (ReplicationResult) that is assembled from the captured
        // payload (which is Sendable) and returned from the transaction block.
        let result = try await destination.transaction(isolation: .serializable) { txn in

            var rowsWritten = 0
            var maxHLC: HLC? = nil

            // 3a. Row copy: upsert each table's rows.
            // conflictColumns is the table's primaryKey — the upsert is idempotent
            // across repeated flush calls (a row with the same PK columns updates
            // in place on the second flush, writing zero new rows if nothing changed).
            for snapshot in payload.tableSnapshots {
                for rowValues in snapshot.rows {
                    // Track HLC values in row columns for watermark tracking.
                    for value in rowValues.values {
                        if case .hlc(let h) = value {
                            if let current = maxHLC {
                                if h > current { maxHLC = h }
                            } else {
                                maxHLC = h
                            }
                        }
                    }

                    _ = try await txn.rowStore.upsert(
                        table: snapshot.tableName,
                        values: rowValues,
                        conflictColumns: snapshot.primaryKey
                    )
                    rowsWritten += 1
                }
            }

            // 3b. Audit copy: append all events from _storagekit_audit.
            // appendBatch is idempotent on (eventID, hlc) — a repeated full flush
            // with the same audit events is a no-op in the audit log.
            if !payload.auditEvents.isEmpty {
                try await txn.auditLog.appendBatch(payload.auditEvents)
            }

            // Track HLC from audit events for watermark.
            for event in payload.auditEvents {
                if let current = maxHLC {
                    if event.hlc > current { maxHLC = event.hlc }
                } else {
                    maxHLC = event.hlc
                }
            }

            // 3c. Blob copy: write every blob from the snapshot into the destination.
            // put() is idempotent on key — a repeated full flush with the same blobs
            // overwrites in place, producing no duplicate keys.
            for blob in payload.blobs {
                try await txn.blobStore.put(key: blob.key, bytes: blob.bytes)
            }

            return ReplicationResult(
                rowsWritten: rowsWritten,
                auditEventsWritten: payload.auditEvents.count,
                blobsWritten: payload.blobs.count,
                hlcWatermark: maxHLC
            )
        }

        log.info("replicate: complete — \(result.rowsWritten) rows, \(result.auditEventsWritten) audit events, \(result.blobsWritten) blobs")

        return ReplicationCursor(
            hlcWatermark: result.hlcWatermark,
            rowsWritten: result.rowsWritten,
            auditEventsWritten: result.auditEventsWritten,
            blobsWritten: result.blobsWritten
        )
    }

    // MARK: - Source snapshot helper

    /// Capture all source data into a Sendable intermediate payload.
    /// This runs entirely outside the destination transaction so there
    /// is no cross-transaction I/O overhead.
    private static func snapshotSource(
        source: any Storage,
        schema: SchemaDeclaration
    ) async throws -> ReplicationPayload {

        // Row snapshot — iterate every schema-declared table.
        // Generated column names are collected per table so we can filter them
        // before staging: writing a GENERATED column to SQLite or PostgreSQL errors;
        // the destination recomputes the value from the base columns.
        var tableSnapshots: [(tableName: String, primaryKey: [String], rows: [[String: TypedValue]])] = []

        for table in schema.tables {
            let generatedColumnNames = Set(table.generatedColumns.map(\.name))
            let rows = try await source.rowStore.query(
                table: table.name,
                where: nil,      // all rows, including tombstones and append-only rows
                orderBy: [],
                limit: nil,
                offset: nil
            )
            // Filter generated columns so the upsert payload only contains base columns.
            let filtered = rows.map { row -> [String: TypedValue] in
                row.values.filter { !generatedColumnNames.contains($0.key) }
            }
            tableSnapshots.append((
                tableName: table.name,
                primaryKey: table.primaryKey,
                rows: filtered
            ))
            log.debug("replicate snapshot: \(filtered.count) rows from '\(table.name)'")
        }

        // Audit snapshot — _storagekit_audit is NOT in schema.tables.
        // Iterate all events (limit: Int.max) from the beginning of time (after: nil).
        let auditEvents = try await source.auditLog.iterate(
            after: nil,
            rowID: nil,
            limit: Int.max
        )
        log.debug("replicate snapshot: \(auditEvents.count) audit events")

        // Blob snapshot — _storagekit_blobs is NOT in schema.tables.
        // Enumerate all keys via listKeys(), then read each blob.
        // Keys are sorted for deterministic write order.
        // A nil return from get(key:) means the key was deleted between
        // listKeys() and get() — this is a TOCTOU race that cannot be
        // prevented with the current protocol (no snapshot isolation on the
        // blob store). We treat it as a transient failure and abort: fail-loud
        // discipline — a missing blob key is surfaced as an error rather than
        // silently dropped, because a destination with a partial blob set
        // cannot detect the gap itself.
        let blobKeys = try await source.blobStore.listKeys()
        var blobs: [(key: BlobKey, bytes: Data)] = []
        for key in blobKeys.sorted() {
            guard let bytes = try await source.blobStore.get(key: key) else {
                throw ReplicationError.storageFailure(
                    detail: "blob key '\(key)' was present in listKeys() but absent in get() — " +
                        "concurrent delete during snapshot; retry the flush"
                )
            }
            blobs.append((key: key, bytes: bytes))
        }
        log.debug("replicate snapshot: \(blobs.count) blobs")

        return ReplicationPayload(
            tableSnapshots: tableSnapshots,
            auditEvents: auditEvents,
            blobs: blobs
        )
    }
}

// MARK: - Internal result type

/// Internal value returned from the transaction block. Sendable, so it can
/// cross the actor boundary imposed by the @Sendable closure requirement.
private struct ReplicationResult: Sendable {
    let rowsWritten: Int
    let auditEventsWritten: Int
    let blobsWritten: Int
    let hlcWatermark: HLC?
}
