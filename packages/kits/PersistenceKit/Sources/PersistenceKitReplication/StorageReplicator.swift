// StorageReplicator.swift
//
// Generic full-snapshot replication primitive (§5 of the PersistenceKit
// Estate Replication spec). Implements replicate(from:to:schema:mode:)
// and exposes flush / hydrate conveniences.
//
// CONTRACT:
//   - Schema gate: source and destination must have the same per-kit
//     schemaVersion. No auto-migration.
//   - Atomicity: the entire destination write is wrapped in a serializable
//     transaction. A crash or error mid-flush leaves the destination at its
//     prior consistent state.
//   - Row snapshot: all rows in schema.tables, including tombstoned rows and
//     rows in append-only tables, are copied verbatim. Generated columns are
//     FILTERED OUT before upsert — the destination backend recomputes them.
//   - Idempotent upsert: conflict key is table.primaryKey, NOT RowHandle.key
//     (which is a random UUID and changes between runs).
//   - Audit copy: _storagekit_audit is NOT in schema.tables; it is copied
//     via a separate auditLog.iterate → appendBatch path. This is load-bearing
//     for downstream matrix rebuild (which consumes the audit log).
//   - Blob copy: _storagekit_blobs is NOT in schema.tables. No GLK kit uses
//     blobStore for content as of 2026-06-05 (confirmed by
//     REPLICATION_GROUND_TRUTH.md §BLOB COPY PATH and by the absence of any
//     blobStore call site in LocusKit, VectorKit, CorpusKit, or GeniusLocusKit).
//     BlobStore also lacks a listKeys() method — the protocol has no way to
//     enumerate all stored keys without knowing them in advance. The blob path
//     is intentionally not implemented here. A future mission that introduces
//     GLK blob usage must also add BlobStore.listKeys() to the protocol and add
//     a blob copy step to this primitive.
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
/// are Sendable (TypedValue, AuditEvent, String are all Sendable).
private struct ReplicationPayload: Sendable {
    /// Per-table row snapshots. Generated columns have been filtered
    /// out from each row's values dict; the destination recomputes them.
    let tableSnapshots: [(tableName: String, primaryKey: [String], rows: [[String: TypedValue]])]
    /// All audit events from the source's _storagekit_audit table.
    let auditEvents: [AuditEvent]
}

// MARK: - StorageReplicator

/// Namespace for the generic storage replication primitive.
///
/// `StorageReplicator.replicate(from:to:schema:mode:)` is the core engine.
/// `flush(from:into:schema:mode:)` and `hydrate(into:from:schema:)` are
/// thin convenience wrappers that name the direction explicitly.
public enum StorageReplicator {

    // MARK: - Core primitive

    /// Copy the full projected state of `source` into `destination`.
    ///
    /// - Parameters:
    ///   - source: The storage to read from (must be open).
    ///   - destination: The storage to write to (must be open).
    ///   - schema: The schema declaration governing which tables to copy.
    ///     This must be the same schema applied to both backends.
    ///   - mode: `.full` copies all rows and audit events atomically.
    ///     `.incremental` throws `ReplicationError.notImplemented`.
    /// - Returns: A `ReplicationCursor` carrying the HLC watermark and counts.
    /// - Throws: `ReplicationError` if the schema gate fails, the mode is
    ///   not implemented, or a storage operation fails.
    public static func replicate(
        from source: any Storage,
        to destination: any Storage,
        schema: SchemaDeclaration,
        mode: ReplicationMode
    ) async throws -> ReplicationCursor {
        switch mode {
        case .full:
            return try await replicateFull(from: source, to: destination, schema: schema)
        case .incremental:
            // §6 incremental is a separate mission. The dirty-set MUST be driven
            // by StorageObserver.observe, not auditLog.iterate — see mission notes
            // and REPLICATION_TRACK_PLAN.md §HARD CONSTRAINT for the rationale.
            throw ReplicationError.notImplemented(
                reason: "§6 incremental replication is not yet implemented. " +
                    "The dirty-set must be driven by StorageObserver.observe, " +
                    "not auditLog — several noun inserts bypass the AuditGate."
            )
        }
    }

    // MARK: - Conveniences

    /// Flush an in-memory storage into a durable storage.
    ///
    /// Equivalent to `replicate(from: inMemory, to: durable, schema: schema, mode: .full)`.
    /// The entire write to `durable` is atomic; a failure leaves `durable` unchanged.
    public static func flush(
        from inMemory: any Storage,
        into durable: any Storage,
        schema: SchemaDeclaration,
        mode: ReplicationMode = .full
    ) async throws -> ReplicationCursor {
        try await replicate(from: inMemory, to: durable, schema: schema, mode: mode)
    }

    /// Hydrate a fresh in-memory storage from a durable storage.
    ///
    /// Equivalent to `replicate(from: durable, to: inMemory, schema: schema, mode: .full)`.
    /// Call this on a freshly-opened InMemoryStorage instance.
    public static func hydrate(
        into inMemory: any Storage,
        from durable: any Storage,
        schema: SchemaDeclaration
    ) async throws -> ReplicationCursor {
        try await replicate(from: durable, to: inMemory, schema: schema, mode: .full)
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

            return ReplicationResult(
                rowsWritten: rowsWritten,
                auditEventsWritten: payload.auditEvents.count,
                hlcWatermark: maxHLC
            )
        }

        log.info("replicate: complete — \(result.rowsWritten) rows, \(result.auditEventsWritten) audit events")

        return ReplicationCursor(
            hlcWatermark: result.hlcWatermark,
            rowsWritten: result.rowsWritten,
            auditEventsWritten: result.auditEventsWritten
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

        return ReplicationPayload(
            tableSnapshots: tableSnapshots,
            auditEvents: auditEvents
        )
    }
}

// MARK: - Internal result type

/// Internal value returned from the transaction block. Sendable, so it can
/// cross the actor boundary imposed by the @Sendable closure requirement.
private struct ReplicationResult: Sendable {
    let rowsWritten: Int
    let auditEventsWritten: Int
    let hlcWatermark: HLC?
}
