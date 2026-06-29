// IncrementalReplicationSession.swift
//
// Observer-driven incremental replication dirty-set (§6).
//
// DESIGN CHOICE — watermark + re-scan (not a durable dirty table):
//
//   Two approaches exist for tracking which rows need replication:
//   A) Durable dirty table: write (table, pk) to a separate SQLite table on
//      each observer event; drain it on sync; delete drained rows.
//   B) In-memory accumulation + watermark: accumulate (table, pkValues) in
//      an actor-isolated set while the session is alive; re-scan missing rows
//      from the source on sync; persist only the HLC watermark in the cursor.
//
//   We chose (B) for three reasons:
//   1. The cursor already carries an HLC watermark; callers that flush/hydrate
//      already manage the cursor lifetime. Extending the cursor to own the
//      dirty-set responsibility is a natural fit and requires no new schema.
//   2. A durable dirty table would bind this module to a specific storage
//      backend schema, violating the module's backend-agnostic design.
//   3. Re-scan on row read is cheap: incremental sync touches only the N
//      dirty rows from the dirty-set, not all rows; re-reading them from the
//      source on each sync run is O(dirty count) regardless.
//
//   RESTART SEMANTICS: if the process restarts, the in-memory dirty-set is
//   lost. The caller handles this by falling back to a full snapshot when the
//   session cannot be resumed (e.g. on first open, or when the dirty-set is
//   not available after a crash). This is correct: a full snapshot is always
//   a valid substitute for an accumulated incremental run.
//
// FAIL-LOUD CONTRACT:
//   A StorageError.corruptStoredValue encountered during a dirty-row read
//   aborts the entire sync run immediately. The error is surfaced to the
//   caller; no partially-committed destination state is left — the destination
//   transaction rolls back. Skipping corrupt rows and continuing would silently
//   poison the destination with a missing subset of the dirty set, which is
//   worse than a failed sync (the caller can retry; a corrupt destination
//   cannot detect itself). See §15 fail-loud read-back commit 0ff08d93.

import Foundation
import PersistenceKit
import SubstrateTypes
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "PersistenceKitReplication")

// MARK: - BlobDirtySet

/// Actor that accumulates dirty blob keys from a StorageObserver blob subscription.
///
/// Each entry is either a pending `put` (key + bytes) or a pending `delete` (key only).
/// Last-write-wins: if a key is put then deleted before the next sync run, the
/// delete supersedes the put. If deleted then put, the put supersedes the delete.
/// This is correct because the incremental session re-reads the live state at sync
/// time for row operations; for blobs we carry the payload in the change event to
/// avoid a second round-trip.
public actor BlobDirtySet {
    /// Pending operations keyed by blob key. The value is (put, bytes) or (delete, nil).
    private var entries: [BlobKey: (event: BlobEvent, bytes: Data?)] = [:]

    /// Record a blob change. Last-write-wins for the same key.
    func accumulate(_ change: BlobChange) {
        entries[change.key] = (change.event, change.bytes)
    }

    /// Drain all accumulated blob operations and return them sorted by key for
    /// deterministic ordering. The set is cleared atomically.
    func drain() -> [(key: BlobKey, event: BlobEvent, bytes: Data?)] {
        let drained = entries.sorted(by: { $0.key < $1.key })
            .map { (key: $0.key, event: $0.value.event, bytes: $0.value.bytes) }
        entries.removeAll()
        return drained
    }

    /// Restore previously-drained blob operations after a failed sync run.
    ///
    /// Union semantics: if a key was already accumulated during the failed run
    /// it is not overwritten by the restored entry — the newer event subsumes the
    /// older one.
    func restore(_ ops: [(key: BlobKey, event: BlobEvent, bytes: Data?)]) {
        for op in ops {
            // Only restore if the key is not already present (newer event takes precedence).
            if entries[op.key] == nil {
                entries[op.key] = (op.event, op.bytes)
            }
        }
    }

    /// Current count — for logging and tests.
    func count() -> Int { entries.count }
}

// MARK: - DirtyKey

/// A (table, primary-key-values) pair that identifies exactly one row
/// in a schema-declared table. The key is the table's declared primaryKey
/// column set; the values are the row's primary key column values at the
/// time the change was observed.
///
/// Ordering is (table, canonicalised-key-string) — deterministic across
/// repeated sync runs for the same dirty set. The sort is load-bearing:
/// two concurrent processes flushing the same dirty set to the same
/// destination will produce the same upsert order, making the resulting
/// transaction deterministic and idempotent.
struct DirtyKey: Sendable, Hashable, Comparable {
    let table: String
    /// Primary key values in column-name order (stable BTree iteration).
    /// Encoded as a string for hashing and comparison.
    let pkEncoded: String

    /// The raw primary-key column values, preserved for the re-scan query.
    let pkValues: [String: TypedValue]

    init(table: String, pkValues: [String: TypedValue]) {
        self.table = table
        // Encode in column-name order (sorted keys) for stable hashing.
        self.pkEncoded = pkValues.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        self.pkValues = pkValues
    }

    static func < (lhs: DirtyKey, rhs: DirtyKey) -> Bool {
        if lhs.table != rhs.table { return lhs.table < rhs.table }
        return lhs.pkEncoded < rhs.pkEncoded
    }
}

// MARK: - DirtySet

/// Actor that accumulates dirty (table, pk) pairs from a StorageObserver
/// subscription and provides a drain operation for sync runs.
///
/// The actor is the single mutable state owner for the dirty-set; the
/// AsyncStream consumer task feeds into it via `accumulate(_:)`. No lock
/// is needed — the actor serialises all access.
public actor DirtySet {
    private var entries: Set<DirtyKey> = []

    // The primary-key column names per table, populated from the schema at
    // session start. Used to extract PK values from the TableChange values dict.
    private let primaryKeys: [String: [String]]

    /// Create a DirtySet for the given schema. The schema is used only to
    /// extract primary-key column names per table; it is not retained after init.
    public init(schema: SchemaDeclaration) {
        var pks: [String: [String]] = [:]
        for table in schema.tables {
            pks[table.name] = table.primaryKey
        }
        self.primaryKeys = pks
    }

    /// Record a change for replication. Called from the observer consumer task.
    ///
    /// Inserts, updates, and deletes all add the same DirtyKey (table + PK
    /// values). At sync time the re-scan determines intent: if the row is
    /// absent in the source, the sync path issues a delete on the destination;
    /// if present, it issues an upsert.
    ///
    /// If the TableChange's values dict does not contain all primary-key
    /// columns for the table, the change is logged and skipped. This protects
    /// against malformed changes from buggy backends; a conforming backend
    /// always emits the PK columns in the values dict.
    func accumulate(_ change: TableChange) {
        guard let pkCols = primaryKeys[change.table] else {
            // Change for a table not in our schema — ignore.
            return
        }
        // Extract PK column values from the change's values dict.
        // TableChange.values carries the full row on insert/update;
        // on delete it carries the identifying values used to find the row.
        guard let values = change.values else {
            // No values dict — cannot identify the row. Log and skip.
            log.warning(
                "incrementalReplication: change on '\(change.table)' with nil values; cannot extract PK, skipping"
            )
            return
        }
        var pkValues: [String: TypedValue] = [:]
        for col in pkCols {
            if let v = values[col] {
                pkValues[col] = v
            } else {
                log.warning(
                    "incrementalReplication: change on '\(change.table)' missing PK column '\(col)'; skipping"
                )
                return
            }
        }
        let key = DirtyKey(table: change.table, pkValues: pkValues)
        entries.insert(key)
    }

    /// Drain all accumulated dirty keys and return them sorted for deterministic
    /// sync ordering. The dirty-set is cleared atomically.
    func drain() -> [DirtyKey] {
        let drained = entries.sorted()
        entries.removeAll()
        return drained
    }

    /// Restore previously-drained keys into the dirty-set after a failed sync run.
    ///
    /// RETRY-PRESERVATION CONTRACT: when sync aborts after a drain, the caller
    /// restores the drained keys so a subsequent retry re-attempts the same rows.
    ///
    /// Union semantics: keys dirtied DURING the failed run (accumulated between
    /// the drain and the restore call) are preserved unchanged. Restored keys
    /// that are already present (newer dirt for the same row) are NOT overwritten
    /// — `Set.insert` is a no-op when the element already exists. This is correct:
    /// a key already in the set means a newer observer event dirtied the same row
    /// after the drain; that newer event subsumes the restored one, and retrying
    /// with it is safe and sufficient.
    func restore(_ keys: [DirtyKey]) {
        for key in keys {
            entries.insert(key)
        }
    }

    /// Current count — for logging and tests.
    func count() -> Int { entries.count }
}

// MARK: - IncrementalReplicationSession

/// An active incremental replication session for one source storage.
///
/// Lifecycle:
///   1. Create a session with `start(source:schema:)`.
///   2. Keep the session alive while the process is running.
///   3. Call `sync(to:schema:)` to push dirty rows and blobs to a destination.
///   4. Discard the session (it cancels its observer tasks) when done.
///
/// The session subscribes to all schema-declared tables on the source's
/// StorageObserver via `observe(table:events:)`, and to the blob store via
/// `observeBlobs()`. Row changes are accumulated in `DirtySet`; blob changes
/// are accumulated in `BlobDirtySet`.
///
/// Thread safety: the session itself is not an actor — it is a value
/// whose subscriber tasks and dirty sets are actor-isolated internally.
/// Swift 6 Sendable conformance is explicit; all mutable state is owned
/// by the DirtySet / BlobDirtySet actors and the Task array (immutable after init).
public final class IncrementalReplicationSession: Sendable {

    // Internal visibility so test code can inspect dirty-set state via
    // @testable import PersistenceKitReplication without exposing the full
    // mutable surface to arbitrary callers.
    let dirtySet: DirtySet
    let blobDirtySet: BlobDirtySet
    private let schema: SchemaDeclaration
    // Observer tasks — cancelled on deinit.
    private let tasks: [Task<Void, Never>]

    // Private init called from the static factory.
    private init(
        dirtySet: DirtySet,
        blobDirtySet: BlobDirtySet,
        schema: SchemaDeclaration,
        tasks: [Task<Void, Never>]
    ) {
        self.dirtySet = dirtySet
        self.blobDirtySet = blobDirtySet
        self.schema = schema
        self.tasks = tasks
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    // MARK: - Factory

    /// Start an incremental replication session on `source`.
    ///
    /// Subscribes to all schema-declared tables for insert, update, and delete
    /// events, and to the blob store for put and delete events. Row changes are
    /// accumulated in `DirtySet`; blob changes in `BlobDirtySet`.
    ///
    /// - Parameters:
    ///   - source: The source storage to observe.
    ///   - schema: The schema governing which tables to watch.
    /// - Returns: A live session. Keep it alive for the duration of the
    ///   replication period; discard to cancel subscriptions.
    public static func start(
        source: any Storage,
        schema: SchemaDeclaration
    ) -> IncrementalReplicationSession {
        let dirty = DirtySet(schema: schema)
        let blobDirty = BlobDirtySet()
        var tasks: [Task<Void, Never>] = []

        // Subscribe to every schema-declared table.
        for table in schema.tables {
            let stream = source.observer.observe(
                table: table.name,
                events: [.insert, .update, .delete]
            )
            // One async task per table. Tasks are cancelled on session deinit.
            let task = Task {
                for await change in stream {
                    await dirty.accumulate(change)
                }
            }
            tasks.append(task)
        }

        // Subscribe to blob changes. One task for the blob stream.
        let blobStream = source.observer.observeBlobs()
        let blobTask = Task {
            for await change in blobStream {
                await blobDirty.accumulate(change)
            }
        }
        tasks.append(blobTask)

        log.info("incrementalReplication: session started on \(schema.tables.count) tables + blob observer")
        return IncrementalReplicationSession(
            dirtySet: dirty,
            blobDirtySet: blobDirty,
            schema: schema,
            tasks: tasks
        )
    }

    // MARK: - Sync

    /// Replicate all dirty rows to `destination`.
    ///
    /// Drains the dirty-set, reads each dirty row from `source`, and upserts
    /// (or deletes) it into `destination` inside a single serializable
    /// transaction.
    ///
    /// FAIL-LOUD: if any dirty row read encounters a StorageError (including
    /// corruptStoredValue), the error is surfaced immediately and the entire
    /// destination transaction is rolled back. No partial state is committed
    /// to the destination.
    ///
    /// RETRY-PRESERVATION: if sync aborts for any reason after the dirty-set
    /// is drained, the drained keys are restored before the error propagates.
    /// A subsequent retry will re-attempt the same rows. Keys dirtied DURING the
    /// failed run are preserved alongside the restored keys (union, no overwrite
    /// of newer dirt for the same row). This ensures no row silently escapes
    /// replication after a transient failure or a corrupt-value abort.
    ///
    /// DETERMINISTIC ORDERING: dirty keys are sorted (table, pk) before
    /// processing, so two concurrent processes syncing the same dirty-set
    /// produce the same upsert order and the result is idempotent.
    ///
    /// AUDIT EVENTS: only audit events with HLC > `fromCursor.hlcWatermark`
    /// are copied, to avoid re-sending events already in the destination.
    ///
    /// - Parameters:
    ///   - source: The source storage to read dirty rows from.
    ///   - destination: The storage to write dirty rows to.
    ///   - fromCursor: The watermark from the previous sync run. Only rows
    ///     dirtied since this run are replicated. Pass a zero-watermark cursor
    ///     for the first incremental sync.
    /// - Returns: A new `ReplicationCursor` with the updated watermark.
    /// - Throws: `ReplicationError` if a storage operation fails. Any error
    ///   during dirty-row reads or destination writes surfaces immediately;
    ///   no partial commit is made.
    public func sync(
        from source: any Storage,
        to destination: any Storage,
        fromCursor: ReplicationCursor
    ) async throws -> ReplicationCursor {

        // Schema gate: both backends must be at the same schema version.
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

        // Drain the dirty-set and blob dirty-set. Sorted for deterministic ordering.
        // RETRY-PRESERVATION: we capture the drained keys before any fallible work.
        // If any error occurs after this point we restore those keys so the next
        // retry re-attempts the same rows/blobs (see DirtySet.restore,
        // BlobDirtySet.restore). The restore is AWAITED in the catch before the
        // error rethrows — never deferred to a detached Task, which would race an
        // immediate retry (drain-before-restore) and reproduce the lost-keys bug
        // nondeterministically.
        let dirtyKeys = await dirtySet.drain()
        let dirtyBlobs = await blobDirtySet.drain()

        if dirtyKeys.isEmpty && dirtyBlobs.isEmpty {
            log.debug("incrementalReplication: dirty-set empty, nothing to sync")
            return fromCursor
        }
        log.info("incrementalReplication: syncing \(dirtyKeys.count) dirty rows, \(dirtyBlobs.count) dirty blobs")

        // RETRY-PRESERVATION guard: restore drained keys/blobs on any error path.
        // The restore is AWAITED before the error propagates (do/catch below),
        // never fire-and-forget: a defer-spawned Task would race an immediate
        // retry — the caller could drain an empty set before the async restore
        // landed, reproducing the lost-keys bug nondeterministically. The Rust
        // port restores synchronously in map_err; this catch-await-rethrow is
        // the Swift equivalent. Keys/blobs accumulated DURING the failed run are
        // already in the dirty sets; restore uses union semantics and will not
        // overwrite newer dirt for the same row/key.
        let result: IncrementalResult
        do {

        // Build a per-table lookup so we know the primary-key columns and
        // which columns are generated (to filter before upsert).
        var tableIndex: [String: TableDeclaration] = [:]
        for table in schema.tables { tableIndex[table.name] = table }

        // Snapshot dirty rows and blob operations from the source BEFORE opening
        // the destination transaction. This mirrors the full-snapshot path: source
        // reads happen outside the destination tx to avoid holding the tx open
        // during I/O. Blob operations use the change-event payload (no re-read).
        let payload = try await snapshotDirtyRows(
            source: source,
            dirtyKeys: dirtyKeys,
            dirtyBlobs: dirtyBlobs,
            tableIndex: tableIndex,
            afterWatermark: fromCursor.hlcWatermark
        )

        // Write destination inside a serializable transaction.
        // If any write fails (including on corruptStoredValue surfaced from source
        // into the payload), the transaction rolls back leaving destination intact.
        result = try await destination.transaction(isolation: .serializable) { txn in
            var rowsWritten = 0
            var deletesWritten = 0
            var maxHLC: HLC? = fromCursor.hlcWatermark

            // 1. Row upserts and deletes.
            for op in payload.rowOps {
                switch op {
                case .upsert(let tableName, let primaryKey, let values):
                    // Track HLC values from row columns for watermark.
                    for value in values.values {
                        if case .hlc(let h) = value {
                            if let current = maxHLC {
                                if h > current { maxHLC = h }
                            } else {
                                maxHLC = h
                            }
                        }
                    }
                    _ = try await txn.rowStore.upsert(
                        table: tableName,
                        values: values,
                        conflictColumns: primaryKey
                    )
                    rowsWritten += 1

                case .delete(let tableName, let predicate):
                    _ = try await txn.rowStore.delete(table: tableName, where: predicate)
                    deletesWritten += 1
                }
            }

            // 2. Audit events newer than the previous watermark.
            let newEvents = payload.auditEvents
            if !newEvents.isEmpty {
                try await txn.auditLog.appendBatch(newEvents)
            }
            for event in newEvents {
                if let current = maxHLC {
                    if event.hlc > current { maxHLC = event.hlc }
                } else {
                    maxHLC = event.hlc
                }
            }

            // 3. Blob puts and deletes from the dirty blob set.
            // put() is idempotent on key; delete() is a no-op if the key is absent.
            var blobPutsWritten = 0
            var blobDeletesWritten = 0
            for blobOp in payload.blobOps {
                switch blobOp {
                case .put(let key, let bytes):
                    try await txn.blobStore.put(key: key, bytes: bytes)
                    blobPutsWritten += 1
                case .delete(let key):
                    try await txn.blobStore.delete(key: key)
                    blobDeletesWritten += 1
                }
            }

            log.info(
                "incrementalReplication: committed \(rowsWritten) upserts, \(deletesWritten) deletes, \(newEvents.count) audit events, \(blobPutsWritten) blob puts, \(blobDeletesWritten) blob deletes"
            )

            return IncrementalResult(
                rowsWritten: rowsWritten,
                deletesWritten: deletesWritten,
                auditEventsWritten: newEvents.count,
                blobOpsWritten: blobPutsWritten + blobDeletesWritten,
                hlcWatermark: maxHLC
            )
        }

        // Transaction committed successfully — the catch below never fires past
        // this point, so the drained keys/blobs are consumed for good.
        } catch {
            await dirtySet.restore(dirtyKeys)
            await blobDirtySet.restore(dirtyBlobs)
            throw error
        }

        return ReplicationCursor(
            hlcWatermark: result.hlcWatermark,
            rowsWritten: result.rowsWritten + result.deletesWritten,
            auditEventsWritten: result.auditEventsWritten,
            blobsWritten: result.blobOpsWritten
        )
    }

    // MARK: - Dirty-row snapshot helper

    /// Snapshot dirty rows and blob operations from the source into a Sendable payload.
    /// Errors during read surface immediately (fail-loud) — no row or blob is skipped.
    private func snapshotDirtyRows(
        source: any Storage,
        dirtyKeys: [DirtyKey],
        dirtyBlobs: [(key: BlobKey, event: BlobEvent, bytes: Data?)],
        tableIndex: [String: TableDeclaration],
        afterWatermark: HLC?
    ) async throws -> IncrementalPayload {

        var rowOps: [RowOp] = []

        for key in dirtyKeys {
            guard let tableDecl = tableIndex[key.table] else {
                // Table no longer in schema (schema changed under us). Skip.
                log.warning("incrementalReplication: dirty key table '\(key.table)' not in schema, skipping")
                continue
            }
            let generatedColumnNames = Set(tableDecl.generatedColumns.map(\.name))

            // Build a predicate that selects the exact row by its PK.
            let predicate = pkPredicate(for: key.pkValues, table: key.table)

            // Query the source for this specific row. At most one row will match.
            // StorageError.corruptStoredValue surfaces here if the row is corrupt —
            // the caller's throw propagates up and aborts the sync (fail-loud).
            let rows = try await source.rowStore.query(
                table: key.table,
                where: predicate,
                orderBy: [],
                limit: 1,
                offset: nil
            )

            if rows.isEmpty {
                // Row was deleted in the source between the observer event and
                // this re-scan. Issue a delete on the destination.
                let delPredicate = pkPredicate(for: key.pkValues, table: key.table)
                rowOps.append(.delete(table: key.table, predicate: delPredicate))
            } else {
                // Filter generated columns before staging for upsert.
                let filteredValues = rows[0].values.filter { !generatedColumnNames.contains($0.key) }
                rowOps.append(.upsert(
                    table: key.table,
                    primaryKey: tableDecl.primaryKey,
                    values: filteredValues
                ))
            }
        }

        // Audit events: only events with HLC strictly after the previous watermark.
        // `iterate(after:rowID:limit:)` is HLC-ordered; `after` is the exclusive
        // lower bound — the InMemoryAuditLog filters with `event.hlc > after`.
        // Events at or before the watermark were already delivered in a previous
        // sync run, so we skip them. On the first sync (afterWatermark == nil)
        // all events are fetched.
        let auditEvents = try await source.auditLog.iterate(
            after: afterWatermark,
            rowID: nil,
            limit: Int.max
        )

        // Blob operations from the dirty blob set.
        // For `put` events the payload carries the bytes captured at observe time
        // (last-write-wins semantics). For `delete` events the bytes are nil.
        // No source re-read is needed for blobs — the change event carries the value,
        // unlike row changes which require a re-scan to get the current row state.
        var blobOps: [BlobOp] = []
        for blobChange in dirtyBlobs {
            switch blobChange.event {
            case .put:
                // bytes is non-nil for put events (see BlobDirtySet contract).
                guard let bytes = blobChange.bytes else {
                    // Defensive: a put event with nil bytes should not occur.
                    // Treat as a corruption and fail-loud.
                    throw ReplicationError.storageFailure(
                        detail: "blob put event for key '\(blobChange.key)' has nil bytes — " +
                            "observer contract violation"
                    )
                }
                blobOps.append(.put(key: blobChange.key, bytes: bytes))
            case .delete:
                blobOps.append(.delete(key: blobChange.key))
            }
        }

        return IncrementalPayload(rowOps: rowOps, auditEvents: auditEvents, blobOps: blobOps)
    }

    // MARK: - Predicate builder

    /// Build a predicate selecting a row by its exact primary-key values.
    /// Multiple PK columns are combined with AND.
    ///
    /// Column.table is the table name extracted from the dirty-key's table field.
    /// The predicate compiler uses Column.name for the SQL column reference;
    /// Column.table is advisory (used in error messages), so passing the actual
    /// table name here is strictly correct.
    private func pkPredicate(for pkValues: [String: TypedValue], table: String) -> StoragePredicate {
        let clauses = pkValues.sorted(by: { $0.key < $1.key }).map { (col, val) -> StoragePredicate in
            .eq(Column(table: table, name: col), val)
        }
        return StoragePredicate.all(clauses)
    }
}

// MARK: - Internal types

/// A row operation to apply during the incremental sync transaction.
private enum RowOp: Sendable {
    case upsert(table: String, primaryKey: [String], values: [String: TypedValue])
    case delete(table: String, predicate: StoragePredicate)
}

/// A blob operation to apply during the incremental sync transaction.
private enum BlobOp: Sendable {
    /// Write `bytes` under `key` in the destination blob store.
    case put(key: BlobKey, bytes: Data)
    /// Delete `key` from the destination blob store.
    case delete(key: BlobKey)
}

/// Sendable payload holding dirty-row operations, new audit events, and dirty blob operations.
private struct IncrementalPayload: Sendable {
    let rowOps: [RowOp]
    let auditEvents: [AuditEvent]
    let blobOps: [BlobOp]
}

/// Internal result from the incremental sync transaction.
private struct IncrementalResult: Sendable {
    let rowsWritten: Int
    let deletesWritten: Int
    let auditEventsWritten: Int
    let blobOpsWritten: Int
    let hlcWatermark: HLC?
}
