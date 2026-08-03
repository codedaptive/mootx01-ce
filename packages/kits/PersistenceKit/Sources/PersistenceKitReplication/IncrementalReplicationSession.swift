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
//      an actor-isolated set while the session is alive; re-scan those rows
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
//   TWO GRANULARITIES OF DIRT — why (B) alone is not enough:
//
//   Approach (B) can only name a row when the observer event carries that
//   row's primary-key values. The durable backends do not always supply them:
//   SQLite emits `values: nil` for predicate `updateRows` and `deleteRows` in
//   both ports, and the Rust PostgreSQL backend emits neither `values` nor
//   `rowKey` for either verb. Nothing else in the change identifies the row —
//   `TableChange.hlc` is nil at every emission site, no schema-wide
//   modified-at column exists, and `rowKey` is a UUID derived from only the
//   FIRST primary-key column (hashed for non-UUID TEXT keys), so it is not
//   invertible and does not identify a row under a composite key.
//
//   So the session tracks dirt at two granularities:
//     ROW dirt   — the change carried its primary-key values. Re-scan exactly
//                  that row; absent in the source means "delete at the
//                  destination", present means "upsert".
//     TABLE dirt — the change did not. The row cannot be named, but the TABLE
//                  can, so the whole table is re-scanned and reconciled: every
//                  source row is upserted, and every destination row whose
//                  primary key is absent from the source is deleted. The
//                  deletion half is what carries an expunge, a tombstone, or
//                  an erasure across; without it a value-less delete would
//                  vanish. It is the row-level form of the rule the
//                  full-snapshot path already applies to blobs
//                  (StorageReplicator §3d, SECFIX-WS2-PK F5): a replica that
//                  holds keys the source does not is divergence.
//
//   A change the session cannot resolve at EITHER granularity — a table that
//   declares no primary key, so there is no column set to reconcile on — does
//   not vanish either. It marks the cycle INCOMPLETE (see the watermark
//   contract below). An observed change always produces propagation or a
//   surfaced refusal; it is never silently dropped.
//
//   MIRROR ASSUMPTION: table-granularity dirt reconciles the destination
//   against the source, so this module's declared model — destination mirrors
//   source — is load-bearing. A destination fanned in from several sources
//   would lose the other sources' rows. That model is already assumed by the
//   restart semantics below and by the blob reconciliation in the snapshot
//   path.
//
//   RESTART SEMANTICS: if the process restarts, the in-memory dirty-set is
//   lost. The caller handles this by falling back to a full snapshot when the
//   session cannot be resumed (e.g. on first open, or when the dirty-set is
//   not available after a crash). This is correct: a full snapshot is always
//   a valid substitute for an accumulated incremental run.
//
// WATERMARK CONTRACT:
//   The audit watermark advances only for a cycle that resolved every change
//   it observed. A cycle carrying an unresolvable change copies no audit
//   events and returns the incoming watermark unchanged, so the next cycle
//   re-reads the same audit range. Advancing the watermark past work that was
//   not done is what would make a missed row permanent: the destination would
//   record that it had replicated a deletion it never received, and only a
//   forced full snapshot could repair it.
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

// MARK: - DirtyDrain

/// One atomic drain of the dirty-set, at all three resolutions the session
/// tracks. Draining is all-or-nothing: a caller can never take the keys and
/// leave the table-granularity dirt behind, which is what would let a
/// value-less change fall out of the cycle unnoticed.
struct DirtyDrain: Sendable {
    /// Rows the session could name, because their change carried its
    /// primary-key values.
    let keys: [DirtyKey]

    /// Tables carrying at least one change the session could NOT name, but
    /// CAN re-scan. Each is re-read in full and reconciled against the
    /// destination during the sync run.
    let rescanTables: [String]

    /// Tables carrying a change the session can neither name nor re-scan,
    /// because the table declares no primary key and reconciliation has no
    /// column set to compare on. A cycle carrying any of these is INCOMPLETE.
    let unresolvableTables: [String]

    /// True only when the session observed nothing at all. Changes the session
    /// could not key are NOT nothing, and must never collapse into this
    /// signal — that collapse is the whole of the silence.
    var isEmpty: Bool {
        keys.isEmpty && rescanTables.isEmpty && unresolvableTables.isEmpty
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

    /// Tables with an observed change whose row could not be identified.
    /// See `DirtyDrain.rescanTables`.
    private var rescanTables: Set<String> = []

    /// Tables with an observed change that can be neither identified nor
    /// reconciled. See `DirtyDrain.unresolvableTables`.
    private var unresolvableTables: Set<String> = []

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
    /// BINDING INVARIANT: a change this method observes is never treated as no
    /// change. It resolves to one of three outcomes, and the two fallbacks are
    /// the reason updates and deletes reach the replica at all:
    ///
    /// 1. **Row dirt.** The change carried every primary-key column, so the
    ///    exact row is recorded. Inserts, updates, and deletes all add the same
    ///    DirtyKey; at sync time the re-scan determines intent — absent in the
    ///    source means delete at the destination, present means upsert.
    /// 2. **Table dirt.** `values` is absent, or present but missing a
    ///    primary-key column, so the row cannot be named. The TABLE is recorded
    ///    for a whole-table re-scan instead. This is the path every predicate
    ///    `update` and `delete` on a durable backend takes: SQLite emits
    ///    `values: nil` for both verbs in both ports, and Rust PostgreSQL emits
    ///    neither `values` nor `rowKey`. Dropping them here would silently
    ///    discard every update and delete on a durable backend — expunge,
    ///    tombstoning, withdrawal, and erasure included — so they are kept.
    /// 3. **Unresolvable.** The table declares no primary key, so there is no
    ///    column set to reconcile source against destination on. Recorded as
    ///    unresolvable, which holds the audit watermark back for the cycle
    ///    rather than letting it advance past work that was not done.
    ///
    /// A change for a table absent from this session's schema is still ignored:
    /// that table is not ours to replicate, which is a scope judgement, not a
    /// failure to resolve.
    func accumulate(_ change: TableChange) {
        guard let pkCols = primaryKeys[change.table] else {
            // Change for a table not in our schema — not ours to replicate.
            return
        }
        guard !pkCols.isEmpty else {
            // No declared primary key: neither naming nor reconciliation is
            // possible. Surface it rather than swallowing it.
            log.error(
                "incrementalReplication: change on '\(change.table)' cannot be resolved — the table declares no primary key; cycle will be reported incomplete"
            )
            unresolvableTables.insert(change.table)
            return
        }
        // TableChange.values carries the full row on insert/upsert; the durable
        // backends leave it nil on predicate update and delete.
        guard let values = change.values else {
            log.info(
                "incrementalReplication: change on '\(change.table)' carries no values; marking the whole table for re-scan"
            )
            rescanTables.insert(change.table)
            return
        }
        var pkValues: [String: TypedValue] = [:]
        for col in pkCols {
            if let v = values[col] {
                pkValues[col] = v
            } else {
                // Values present but not carrying the full key — same remedy as
                // no values at all: the row is unnameable, the table is not.
                log.info(
                    "incrementalReplication: change on '\(change.table)' is missing PK column '\(col)'; marking the whole table for re-scan"
                )
                rescanTables.insert(change.table)
                return
            }
        }
        let key = DirtyKey(table: change.table, pkValues: pkValues)
        entries.insert(key)
    }

    /// Drain everything accumulated since the last drain, sorted for
    /// deterministic sync ordering. All three sets are cleared atomically —
    /// see `DirtyDrain`.
    func drain() -> DirtyDrain {
        let drained = DirtyDrain(
            keys: entries.sorted(),
            rescanTables: rescanTables.sorted(),
            unresolvableTables: unresolvableTables.sorted()
        )
        entries.removeAll()
        rescanTables.removeAll()
        unresolvableTables.removeAll()
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
    ///
    /// All three resolutions are restored together. Restoring only the keys
    /// would drop the table-granularity dirt on a failed run, which is the same
    /// silent loss this session exists to prevent — just moved to the retry path.
    func restore(_ drained: DirtyDrain) {
        for key in drained.keys {
            entries.insert(key)
        }
        rescanTables.formUnion(drained.rescanTables)
        unresolvableTables.formUnion(drained.unresolvableTables)
    }

    /// Count of individually-named dirty rows — for logging and tests. Table-
    /// granularity dirt is deliberately NOT counted here: one entry stands for
    /// an unknown number of rows, so folding it into this number would make the
    /// count mean two different things. Use `pendingRescanTables()` for that.
    func count() -> Int { entries.count }

    /// Tables awaiting a whole-table re-scan, sorted — for logging and tests.
    func pendingRescanTables() -> [String] { rescanTables.sorted() }

    /// Tables carrying a change that can be neither named nor reconciled,
    /// sorted — for logging and tests.
    func pendingUnresolvableTables() -> [String] { unresolvableTables.sorted() }
}

// MARK: - IncrementalSyncOutcome

/// The result of one incremental sync cycle: the cursor to persist, plus what
/// the cycle had to do to resolve what it observed.
///
/// The cursor alone cannot carry this. `ReplicationCursor` is the DURABLE
/// watermark a caller stores and passes back on the next run; cycle resolution
/// is a report about a single run and has no meaning once persisted. Keeping
/// them apart also means a caller that only wants the watermark keeps reading
/// `.cursor` and is unaffected by anything here.
///
/// A caller that ignores `unresolvedTables` still cannot lose data silently:
/// the watermark in `cursor` did not advance for an incomplete cycle, so the
/// next run re-reads the same audit range.
public struct IncrementalSyncOutcome: Sendable, Equatable {

    /// The watermark to persist and pass to the next `sync` call.
    ///
    /// For an incomplete cycle this carries the INCOMING watermark unchanged —
    /// see `unresolvedTables`.
    public let cursor: ReplicationCursor

    /// Tables this cycle re-scanned in full because it observed a change it
    /// could not attribute to a row (sorted).
    ///
    /// Non-empty is normal, not an error: every predicate update and delete on
    /// a durable backend arrives without values and lands here. It is reported
    /// because a whole-table re-scan costs O(table), not O(dirty rows), and a
    /// caller watching replication cost needs to see when that happens.
    public let rescannedTables: [String]

    /// Tables carrying a change this cycle could resolve at NO granularity —
    /// the table declares no primary key, so it can be neither named nor
    /// reconciled (sorted).
    ///
    /// Non-empty means the cycle is INCOMPLETE: no audit events were copied and
    /// `cursor.hlcWatermark` is the incoming watermark, unmoved. Row work that
    /// COULD be resolved was still propagated — an unresolvable change withholds
    /// the watermark, it does not veto the rest of the cycle.
    public let unresolvedTables: [String]

    /// Whether every observed change was resolved. False means the audit
    /// watermark deliberately did not advance.
    public var isComplete: Bool { unresolvedTables.isEmpty }

    public init(
        cursor: ReplicationCursor,
        rescannedTables: [String] = [],
        unresolvedTables: [String] = []
    ) {
        self.cursor = cursor
        self.rescannedTables = rescannedTables
        self.unresolvedTables = unresolvedTables
    }
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
    /// are copied, to avoid re-sending events already in the destination. An
    /// INCOMPLETE cycle copies none at all — see the watermark contract below.
    ///
    /// TABLE-GRANULARITY DIRT: a change that arrived without primary-key values
    /// marks its whole table for re-scan (see `DirtySet.accumulate`). Every
    /// source row in such a table is upserted, and every destination row whose
    /// primary key is absent from the source is deleted. That deletion pass is
    /// what carries a value-less delete — an expunge, a tombstone, an erasure —
    /// across to the replica.
    ///
    /// WATERMARK: advances only for a cycle that resolved every change it
    /// observed. If any observed change was unresolvable, no audit events are
    /// copied and the returned cursor carries `fromCursor`'s watermark
    /// unchanged, so the next cycle re-reads the same range. Row work that
    /// could be resolved still propagates.
    ///
    /// - Parameters:
    ///   - source: The source storage to read dirty rows from.
    ///   - destination: The storage to write dirty rows to.
    ///   - fromCursor: The watermark from the previous sync run. Only rows
    ///     dirtied since this run are replicated. Pass a zero-watermark cursor
    ///     for the first incremental sync.
    /// - Returns: An `IncrementalSyncOutcome` carrying the cursor to persist
    ///   and this cycle's resolution report.
    /// - Throws: `ReplicationError` if a storage operation fails. Any error
    ///   during dirty-row reads or destination writes surfaces immediately;
    ///   no partial commit is made.
    public func sync(
        from source: any Storage,
        to destination: any Storage,
        fromCursor: ReplicationCursor
    ) async throws -> IncrementalSyncOutcome {

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
        let drained = await dirtySet.drain()
        let dirtyKeys = drained.keys
        let dirtyBlobs = await blobDirtySet.drain()

        // The early return fires ONLY when nothing at all was observed. It may
        // never stand in for "changes were observed but could not be keyed":
        // that equivalence is what would make a deletions-only cycle
        // indistinguishable from an idle one.
        if drained.isEmpty && dirtyBlobs.isEmpty {
            log.debug("incrementalReplication: no observed changes, nothing to sync")
            return IncrementalSyncOutcome(cursor: fromCursor)
        }

        // A cycle is complete when every observed change resolved to either a
        // named row or a re-scannable table. Unresolvable changes withhold the
        // watermark (see the watermark contract in the type doc).
        let cycleResolved = drained.unresolvableTables.isEmpty
        if !cycleResolved {
            log.error(
                "incrementalReplication: cycle INCOMPLETE — unresolvable changes on \(drained.unresolvableTables.joined(separator: ", ")); audit watermark held at its incoming value and no audit events copied"
            )
        }
        log.info(
            "incrementalReplication: syncing \(dirtyKeys.count) dirty rows, \(drained.rescanTables.count) re-scan tables, \(dirtyBlobs.count) dirty blobs"
        )

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
            rescanTables: drained.rescanTables,
            dirtyBlobs: dirtyBlobs,
            tableIndex: tableIndex,
            afterWatermark: fromCursor.hlcWatermark,
            copyAuditEvents: cycleResolved
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

            // 1b. Reconcile every wholly-dirty table: delete destination rows
            // whose primary key is absent from the source. The upserts for
            // these tables are already in rowOps above, so what remains is the
            // half a value-less change cannot express — which rows went away.
            // Without this pass an expunge, tombstone, or erasure would leave
            // the removed content live at the destination.
            //
            // Same rule the full-snapshot path applies to blobs
            // (StorageReplicator §3d, SECFIX-WS2-PK F5): keys the destination
            // holds and the source does not are divergence.
            //
            // Both sides are encoded through DirtyKey so the comparison cannot
            // drift from the encoding the dirty-set itself uses.
            for rescan in payload.tableRescans {
                let destinationRows = try await txn.rowStore.query(
                    table: rescan.table,
                    where: nil,
                    orderBy: [],
                    limit: nil,
                    offset: nil
                )
                for row in destinationRows {
                    guard let pkValues = Self.extractPKValues(
                        from: row.values, columns: rescan.primaryKey
                    ) else {
                        // A destination row missing a declared PK column cannot
                        // be compared, and guessing would risk deleting a row
                        // the source still holds. Fail loud (§15).
                        throw ReplicationError.storageFailure(
                            detail: "incremental re-scan of '\(rescan.table)': destination row is " +
                                "missing a primary-key column; cannot reconcile against the source"
                        )
                    }
                    let encoded = DirtyKey(table: rescan.table, pkValues: pkValues).pkEncoded
                    guard !rescan.sourcePKEncodings.contains(encoded) else { continue }
                    // Note: on an append-only table the backend rejects DELETE
                    // by contract and this throws. That is unreachable in
                    // practice — an append-only table also rejects the UPDATE
                    // and DELETE that are the only sources of value-less
                    // changes — and a loud failure is the right answer if it
                    // ever is reached. A silent skip here would be exactly the
                    // quiet exemption this session exists to remove.
                    _ = try await txn.rowStore.delete(
                        table: rescan.table,
                        where: pkPredicate(for: pkValues, table: rescan.table)
                    )
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
            await dirtySet.restore(drained)
            await blobDirtySet.restore(dirtyBlobs)
            throw error
        }

        // WATERMARK GATE: an incomplete cycle keeps the incoming watermark.
        // `result.hlcWatermark` starts at `fromCursor.hlcWatermark` and only
        // ever grows, so pinning it back here is the whole of the gate.
        let watermark = cycleResolved ? result.hlcWatermark : fromCursor.hlcWatermark

        return IncrementalSyncOutcome(
            cursor: ReplicationCursor(
                hlcWatermark: watermark,
                rowsWritten: result.rowsWritten + result.deletesWritten,
                auditEventsWritten: result.auditEventsWritten,
                blobsWritten: result.blobOpsWritten
            ),
            rescannedTables: drained.rescanTables,
            unresolvedTables: drained.unresolvableTables
        )
    }

    // MARK: - Dirty-row snapshot helper

    /// Snapshot dirty rows and blob operations from the source into a Sendable payload.
    /// Errors during read surface immediately (fail-loud) — no row or blob is skipped.
    ///
    /// - Parameters:
    ///   - rescanTables: Tables to read in FULL because a change on them could
    ///     not be attributed to a row. Every source row is staged for upsert and
    ///     the table's source primary-key set is captured so the caller can
    ///     delete destination rows the source no longer has.
    ///   - copyAuditEvents: False for an incomplete cycle. Audit events and the
    ///     watermark move together: copying events for a cycle whose watermark
    ///     is held back would re-copy the same events on the next run, so an
    ///     incomplete cycle copies none.
    private func snapshotDirtyRows(
        source: any Storage,
        dirtyKeys: [DirtyKey],
        rescanTables: [String],
        dirtyBlobs: [(key: BlobKey, event: BlobEvent, bytes: Data?)],
        tableIndex: [String: TableDeclaration],
        afterWatermark: HLC?,
        copyAuditEvents: Bool
    ) async throws -> IncrementalPayload {

        var rowOps: [RowOp] = []
        var tableRescans: [TableRescan] = []

        // Whole-table re-scan first, so per-key work on the same table can be
        // skipped below: a table being read in full already covers every row in
        // it, and re-querying those rows one at a time would be pure waste.
        let rescanSet = Set(rescanTables)
        for table in rescanTables {
            guard let tableDecl = tableIndex[table] else {
                // Table left the schema between the observer event and the
                // re-scan. Nothing to reconcile against.
                log.warning("incrementalReplication: re-scan table '\(table)' not in schema, skipping")
                continue
            }
            let generatedColumnNames = Set(tableDecl.generatedColumns.map(\.name))

            // Unbounded read: correctness first. A value-less change names no
            // row, so the only sound lower bound on what to re-read is the
            // whole table. This is why `IncrementalSyncOutcome.rescannedTables`
            // reports which tables paid that cost.
            let sourceRows = try await source.rowStore.query(
                table: table, where: nil, orderBy: [], limit: nil, offset: nil
            )

            var sourcePKEncodings: Set<String> = []
            for row in sourceRows {
                guard let pkValues = Self.extractPKValues(
                    from: row.values, columns: tableDecl.primaryKey
                ) else {
                    // A source row missing a declared PK column would make the
                    // reconciliation set incomplete, and an incomplete source
                    // set deletes destination rows that should have survived.
                    throw ReplicationError.storageFailure(
                        detail: "incremental re-scan of '\(table)': source row is missing a " +
                            "primary-key column; the re-scan set would be incomplete"
                    )
                }
                sourcePKEncodings.insert(DirtyKey(table: table, pkValues: pkValues).pkEncoded)
                let filteredValues = row.values.filter { !generatedColumnNames.contains($0.key) }
                rowOps.append(.upsert(
                    table: table,
                    primaryKey: tableDecl.primaryKey,
                    values: filteredValues
                ))
            }
            tableRescans.append(TableRescan(
                table: table,
                primaryKey: tableDecl.primaryKey,
                sourcePKEncodings: sourcePKEncodings
            ))
        }

        for key in dirtyKeys where !rescanSet.contains(key.table) {
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
        //
        // An incomplete cycle copies none: its watermark stays where it was, so
        // copying events now would append them again on the next run.
        let auditEvents = copyAuditEvents
            ? try await source.auditLog.iterate(after: afterWatermark, rowID: nil, limit: Int.max)
            : []

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

        return IncrementalPayload(
            rowOps: rowOps,
            tableRescans: tableRescans,
            auditEvents: auditEvents,
            blobOps: blobOps
        )
    }

    // MARK: - Primary-key helpers

    /// Pull the declared primary-key columns out of a row's values.
    ///
    /// Returns nil when any declared PK column is absent — the caller must
    /// treat that as a failure rather than reconciling on a partial key, since
    /// a partial key cannot distinguish two rows and would license deleting the
    /// wrong one. Static because it is called from inside the destination
    /// transaction's `@Sendable` closure and touches no session state.
    private static func extractPKValues(
        from values: [String: TypedValue],
        columns: [String]
    ) -> [String: TypedValue]? {
        var out: [String: TypedValue] = [:]
        for col in columns {
            guard let v = values[col] else { return nil }
            out[col] = v
        }
        return out
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

/// One wholly-dirty table: the source's complete primary-key set for it, so the
/// destination can be reconciled against the source inside the sync transaction.
///
/// Only the ENCODED keys are carried, not the rows — the upserts are already in
/// `IncrementalPayload.rowOps`, and all this pass needs is set membership.
private struct TableRescan: Sendable {
    let table: String
    let primaryKey: [String]
    /// `DirtyKey.pkEncoded` for every row present in the source at snapshot
    /// time. A destination row whose encoding is absent from this set was
    /// removed at the source and is deleted at the destination.
    let sourcePKEncodings: Set<String>
}

/// Sendable payload holding dirty-row operations, whole-table reconciliations,
/// new audit events, and dirty blob operations.
private struct IncrementalPayload: Sendable {
    let rowOps: [RowOp]
    let tableRescans: [TableRescan]
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
